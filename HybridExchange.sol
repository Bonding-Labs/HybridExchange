// SPDX-License-Identifier: UNLICENCED
// Copyright: Bonding Labs - Begic Nedim

pragma solidity ^0.8.0;
import "./HybridBondingCurve.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MemeCoin.sol";

/**
 * @title HybridExchange
 * @notice Single deposit AMM storing MemeCoin + USDT, with a hybrid bonding curve.
 *         - Only 'router' can call buy(...) or sell(...) for slippage checks.
 *         - 'feeCollector' can withdraw accumulated fees from the exchange's USDT balance.
 */
contract HybridExchange is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Info about each MemeCoin pool
    struct PoolInfo {
        bool exists;        // if the pool is registered
        address creator;    // who created it
        uint256 tokenSupply;// how many MemeCoins are currently in this exchange
        uint256 usdtReserve;// how many USDT are currently in this exchange
    }

    // External references
    IERC20 public USDT;       // set via setUSDT(...)
    address public factory;   // set via setFactory(...)
    address public feeCollector; 
    address public router;    // set via setRouter(...)

    // Fees + supply constraints
    uint256 public constant FEE_BPS = 50;  // 0.5% fee
    uint256 public constant MAX_POOL_SUPPLY = 1e12 * 1e6; // limit ~ 1 trillion MemeCoins w/ 6 decimals

    // Mapping from MemeCoin => PoolInfo
    mapping(address => PoolInfo) public pools;

    // Events
    event PoolRegistered(address indexed token, address indexed creator, uint256 initialSupply, uint256 initialUSDT);
    event Bought(address indexed buyer, address indexed token, uint256 usdtIn, uint256 tokenOut);
    event Sold(address indexed seller, address indexed token, uint256 tokenIn, uint256 usdtOut);
    event FeeCollectorChanged(address indexed oldCollector, address indexed newCollector);
    event RouterChanged(address indexed oldRouter, address indexed newRouter);
    event FeesWithdrawn(address indexed collector, uint256 amount);

    /**
     * @param _initialOwner => who owns this exchange
     */
    constructor(address _initialOwner) Ownable(_initialOwner) {
        require(_initialOwner != address(0), "Invalid owner");
    }

    /** 
     * @notice Sets the USDT token after deployment. 
     */
    function setUSDT(address _usdt) external onlyOwner {
        require(_usdt != address(0), "Invalid USDT");
        USDT = IERC20(_usdt);
    }

    /**
     * @notice Sets the factory address after deployment.
     */
    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory");
        factory = _factory;
    }

    /**
     * @notice Sets the router address after deployment.
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        address old = router;
        router = _router;
        emit RouterChanged(old, router);
    }

    /**
     * @notice Sets the feeCollector address. 
     */
    function setFeeCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "Collector=0");
        address old = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorChanged(old, newCollector);
    }

    /**
     * @notice feeCollector can withdraw fees from the contract's USDT balance
     */
    function withdrawFees(uint256 amount) external {
        require(msg.sender == feeCollector, "Not feeCollector");
        uint256 bal = USDT.balanceOf(address(this));
        require(amount <= bal, "Not enough fees");
        USDT.safeTransfer(feeCollector, amount);
        emit FeesWithdrawn(feeCollector, amount);
    }

    /**
     * @notice onlyRouter => for buy/sell
     */
    modifier onlyRouter() {
        require(msg.sender == router, "Not router");
        _;
    }

    /**
     * @notice Factory => calls => sets up a new pool
     * @dev We expect the factory to have MemeCoins + USDT, 
     *      it must have approved HybridExchange for these amounts.
     */
    function registerNewToken(
        address token,
        address creator,
        uint256 initialSupply,
        uint256 initialLiquidityUSDT
    ) external {
        require(msg.sender == factory, "Only factory");
        require(!pools[token].exists, "Pool exists");
        require(initialSupply <= MAX_POOL_SUPPLY, "Exceed max supply");
        require(initialLiquidityUSDT > 0, "No zero USDT");

        // Transfer MemeCoins + USDT from msg.sender => exchange
        // (msg.sender is typically the factory)
        IERC20(token).safeTransferFrom(msg.sender, address(this), initialSupply);
        USDT.safeTransferFrom(msg.sender, address(this), initialLiquidityUSDT);

        pools[token] = PoolInfo({
            exists: true,
            creator: creator,
            tokenSupply: initialSupply,
            usdtReserve: initialLiquidityUSDT
        });

        emit PoolRegistered(token, creator, initialSupply, initialLiquidityUSDT);
    }

    /**
     * @notice getPrice(...) => current bonding-curve price in USDT per MemeCoin
     */
    function getPrice(address token, uint256 supply) public view returns (uint256) {
        PoolInfo storage p = pools[token];
        require(p.exists, "Pool not exist");
        require(supply <= MAX_POOL_SUPPLY, "Supply too large");

        MemeCoin mc = MemeCoin(token);
        uint256 B_ = mc.B();
        uint256 L_ = mc.L();
        uint256 E_ = mc.E();
        uint256 T_ = mc.T();

        return HybridBondingCurve.getPrice(supply, B_, L_, E_, T_);
    }

    /**
     * @notice buy MemeCoin with USDT, only router => external slippage checks
     */
    function buy(
        address token,
        uint256 usdtAmount,
        address buyer
    ) external nonReentrant onlyRouter returns (uint256 tokenOut) {
        PoolInfo storage p = pools[token];
        require(p.exists, "No pool");

        // 1) router => exchange
        USDT.safeTransferFrom(msg.sender, address(this), usdtAmount);

        // 2) fee
        uint256 fee = (usdtAmount * FEE_BPS) / 10000;
        uint256 usdtMinusFee = usdtAmount - fee;

        // 3) price
        uint256 price = getPrice(token, p.tokenSupply);
        tokenOut = (usdtMinusFee * 1e6) / price;

        uint256 newSupply = p.tokenSupply - tokenOut;
        require(newSupply <= MAX_POOL_SUPPLY, "newSupply invalid");

        // 4) update the pool
        p.tokenSupply = newSupply;
        p.usdtReserve += usdtMinusFee;

        // 5) transfer MemeCoin to buyer
        IERC20(token).safeTransfer(buyer, tokenOut);

        emit Bought(buyer, token, usdtAmount, tokenOut);
        return tokenOut;
    }

    /**
     * @notice sell MemeCoin => get USDT, only router => external slippage checks
     */
    function sell(
        address token,
        uint256 tokenAmount,
        address seller
    ) external nonReentrant onlyRouter returns (uint256 usdtOut) {
        PoolInfo storage p = pools[token];
        require(p.exists, "No pool");

        // 1) router => exchange
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // 2) price
        uint256 supplyPlus = p.tokenSupply + tokenAmount;
        require(supplyPlus <= MAX_POOL_SUPPLY, "Exceed max supply");

        uint256 price = getPrice(token, supplyPlus);
        usdtOut = (tokenAmount * price) / 1e6;

        // 3) fee
        uint256 fee = (usdtOut * FEE_BPS) / 10000;
        uint256 usdtMinusFee = usdtOut - fee;

        require(usdtMinusFee <= p.usdtReserve, "Not enough USDT in reserve");

        // 4) update pool
        p.tokenSupply = supplyPlus;
        p.usdtReserve -= usdtMinusFee;

        // 5) transfer USDT to seller
        USDT.safeTransfer(seller, usdtMinusFee);

        emit Sold(seller, token, tokenAmount, usdtMinusFee);
        return usdtMinusFee;
    }
}

