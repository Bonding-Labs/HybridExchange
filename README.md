
## What Is **HybridExchange**?

**HybridExchange** is a specialized Automated Market Maker (AMM) contract designed to hold exactly **one** pool of:
1. A custom MemeCoin token.
2. USDT.

It allows users to **buy** MemeCoin with USDT or **sell** MemeCoin back into USDT, using a **"hybrid bonding curve"** to determine the token’s price. It also charges a small trading fee, which is collected in USDT.

---

## Key Points of the Contract

1. **Single-Deposit AMM**  
   - Unlike typical AMMs that allow many users to deposit liquidity, this design puts 100% of the MemeCoin supply plus some USDT in a single pool.  
   - Thus a fair launch is ensured and rug pulls are prevented.
   - Since memecoins "lose steam" in later stages of their lifecycle the exponetial phase which is meant to push prices upwards actually acts as a facilitator to reverse/mitigate the price decline.

2. **One Pool Per MemeCoin**  
   - Each MemeCoin has an entry in `pools[memeCoinAddress]` that tracks:
     - `tokenSupply`: how many MemeCoins this exchange contract currently holds.
     - `usdtReserve`: how many USDT the exchange holds for that particular MemeCoin.
     - `exists`: boolean to ensure the pool was properly set up.
     - `creator`: who created (registered) that MemeCoin’s pool (mostly informational).

3. **Factory & Initialization**  
   - A **Factory** contract calls `registerNewToken(...)` to create a new pool.  
   - That function expects:
     - The MemeCoin tokens (`initialSupply`)
     - The initial USDT (`initialLiquidityUSDT`)
     - Both amounts must be transferred into the exchange contract.  
   - Once registered, the `pools[memeCoin].exists` is set to `true`, and anyone can then trade (buy or sell) with it—subject to your router logic.

4. **Hybrid Bonding Curve Pricing**  
   - The contract references `HybridBondingCurve.getPrice(...)` to compute the current price of the MemeCoin in USDT.  
   - This curve is **piecewise** (logarithmic in early supply, exponential at higher supply), providing a smooth shift from cheaper to more expensive tokens as the supply changes.  

5. **Buying and Selling**  
   - **Buy**: A user sends some USDT to the contract (through a “router” that checks slippage). The exchange calculates how many MemeCoins to give in return.  
   - **Sell**: A user sends MemeCoins back to the contract, receiving USDT in exchange, reducing the MemeCoin supply in the contract.  
   - These calls are restricted via `onlyRouter()`, meaning normal users cannot directly call the exchange—your Router contract orchestrates trades (which, among other things, can enforce slippage/tolerance checks).

6. **Fees**  
   - On each trade, a small percentage (by default, 0.5% in `FEE_BPS = 50`) is taken from the user’s USDT.  
   - That fee remains in the contract’s USDT balance.  
   - A designated `feeCollector` can later call `withdrawFees(...)` to pull these fees out in USDT.  

7. **Ownership & Configuration**  
   - The contract inherits from **Ownable**, meaning the deployer or assigned owner can call certain admin functions:
     - `setUSDT(...)` to configure the USDT address after deployment.
     - `setFactory(...)` to authorize the factory that can create new pools.
     - `setRouter(...)` to designate which router contract can call `buy(...)` and `sell(...)`.
     - `setFeeCollector(...)` to set or change the address that collects fees.

8. **Checks to Ensure Safety**  
   - The contract uses **ReentrancyGuard** to prevent reentrancy attacks.  
   - It also uses `SafeERC20` from OpenZeppelin to handle token transfers safely.  
   - Hard-coded maximum supply (`MAX_POOL_SUPPLY`) ensures that the contract refuses to handle MemeCoins beyond a certain limit (e.g., 1 trillion in 6 decimals).

---

## Flow of a Typical Trade

1. **Pool Creation**  
   - The **Factory** contract calls `registerNewToken(...)`.  
   - MemeCoins and USDT are transferred from the factory into the exchange.  
   - A `PoolInfo` record is created in `pools[...]` with the token supply and USDT reserve.

2. **Buy**  
   - The user calls `router.buyToken(...)`, which internally calls `exchange.buy(...)`.  
   - The user sends USDT to the exchange.  
   - A small fraction is taken as a fee. The remainder is used to calculate how many MemeCoins to dispense, based on the bonding curve price.  
   - The exchange’s internal `tokenSupply` decreases by `tokenOut`, the `usdtReserve` increases by the USDT minus fee.

3. **Sell**  
   - The user calls `router.sellToken(...)`, which calls `exchange.sell(...)`.  
   - The user’s MemeCoins are transferred in.  
   - The exchange calculates how much USDT to return, minus fees, based on the updated supply.  
   - `tokenSupply` in the contract goes **up** by that `tokenAmount` (because the exchange now holds more MemeCoin), while the `usdtReserve` goes **down** accordingly.

4. **Price Updates**  
   - Every buy or sell changes the MemeCoin supply and/or USDT reserve in the pool.  
   - On the **next** trade, `getPrice(...)` sees the updated supply and returns a new price, meaning price is dynamically updated trade-by-trade.

---

## Summary

1. **Objective**: Provide an **AMM-like** environment for a single MemeCoin–USDT pair, governed by a **hybrid bonding curve**.  
2. **Mechanics**:
   - One pool per MemeCoin, storing all MemeCoins + USDT in the same contract.  
   - Buys and sells update `tokenSupply` and `usdtReserve`.  
   - A small trading fee is collected in USDT.  
3. **Additional**:
   - Requires a “router” contract to call buy/sell, so normal users do not bypass slippage checks.  
   - The owner can set addresses (factory, router, feeCollector) and withdraw fees.  

Thus, **HybridExchange** is an on-chain, single-pool exchange solution that implements a piecewise (log->exp) bonding curve for token price discovery, while charging a small fee and allowing a single “Router” to handle user trades safely.
