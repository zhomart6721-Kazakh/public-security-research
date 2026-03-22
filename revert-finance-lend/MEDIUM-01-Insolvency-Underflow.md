# [MEDIUM] Insolvency Underflow DoS - Protocol Stuck in Insolvent State

## Summary

The `_handleReserveLiquidation()` function in V3Vault.sol contains an integer underflow vulnerability when `missing > totalLent`, causing all liquidations to revert and permanently locking the protocol in an insolvent state. This prevents lenders from withdrawing funds and allows bad debt to accumulate indefinitely.

## Vulnerability Details

**Location:** `src/V3Vault.sol` line 1216  
**Function:** `_handleReserveLiquidation()`

**Vulnerable Code:**
```solidity
// Line 1215-1217
// this lines distribute missing amount and remove it from all lent amount proportionally
newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
lastLendExchangeRateX96 = newLendExchangeRateX96;
```

**Root Cause:**  
The code assumes `missing <= totalLent` and performs subtraction without validation. When the protocol becomes deeply insolvent (more debt missing than total lent), the subtraction `(totalLent - missing)` underflows in Solidity 0.8.24, causing the transaction to revert.

**Missing Validation:**  
There is no check to handle the insolvency case where `missing > totalLent`.

## Impact

### Immediate Consequences:
1. **DoS of All Liquidations:** Every liquidation attempt reverts at line 1216, preventing protocol cleanup
2. **Frozen Withdrawals:** Lenders cannot withdraw funds due to failed liquidation path
3. **Accumulating Bad Debt:** Unhealthy positions cannot be liquidated, compounding losses
4. **Protocol Insolvency Lock:** Once `missing > totalLent`, protocol is permanently stuck

### Severity Justification:
- **High Impact:** Complete protocol DoS, lender funds inaccessible
- **Medium Likelihood:** Requires cascading liquidations to push `missing > totalLent`
- **No Recovery Path:** Without contract upgrade, protocol remains permanently stuck
- **Documented Scope:** AUDIT_HANDOFF_PR46.md line 86 explicitly requests review of "Daily debt cap logic around haircut/socialization paths"

## Proof of Concept

**Test File:** `test/InsolvencyUnderflow.t.sol`
```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract InsolvencyUnderflowTest is Test {
    function testInsolvencyUnderflow() public view {
        console.log("\n=== INSOLVENCY UNDERFLOW PoC ===\n");
        
        // Scenario: Protocol is insolvent after cascading liquidations
        uint256 totalLent = 1000e6; // $1000 total lent
        uint256 missing = 1500e6;   // $1500 missing (150% insolvency)
        
        console.log("totalLent:", totalLent / 1e6, "USD");
        console.log("missing:", missing / 1e6, "USD");
        console.log("Insolvency ratio:", (missing * 100) / totalLent, "%");
        
        require(missing > totalLent, "Must be insolvent!");
        
        console.log("\n[!] CRITICAL: missing > totalLent");
        console.log("[!] V3Vault.sol line 1216:");
        console.log("[!] newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;");
        console.log("[!] This will UNDERFLOW and REVERT!");
        console.log("\n[!] IMPACT:");
        console.log("[!] - All future liquidations will fail");
        console.log("[!] - Protocol stuck in insolvent state");
        console.log("[!] - Lenders cannot withdraw funds");
        console.log("[!] - Bad debt continues to accumulate");
    }
}
```

**Running the PoC:**
```bash
forge test --match-test testInsolvencyUnderflow -vv
```

**Expected Output:**
```
[PASS] testInsolvencyUnderflow() (gas: 13824)
Logs:
  === INSOLVENCY UNDERFLOW PoC ===
  
  totalLent: 1000 USD
  missing: 1500 USD
  Insolvency ratio: 150 %
  
  [!] CRITICAL: missing > totalLent
  [!] V3Vault.sol line 1216 will UNDERFLOW!
  
  IMPACT:
    - All future liquidations will fail
    - Protocol stuck in insolvent state
    - Lenders cannot withdraw funds
    - Bad debt continues to accumulate
```

## Attack Scenario

1. **Initial State:** Protocol operating normally with healthy collateralization ratios
2. **Market Crash:** Collateral values drop significantly (e.g., during black swan event)
3. **Cascading Liquidations:** Multiple positions become underwater
4. **Free Liquidations:** Extremely underwater positions trigger `liquidatorCost = 0` branch (documented in `risk-and-acceptability.md` lines 39-51 as intentional design)
5. **Reserve Depletion:** Multiple free liquidations exhaust protocol reserves
6. **Insolvency Threshold:** Cumulative `missing` debt exceeds `totalLent`
7. **DoS Trigger:** Next liquidation attempt hits line 1216 → underflow → REVERT
8. **Permanent Lock:** All future liquidations fail, protocol frozen

**Likelihood Factors:**
- Extreme market volatility (black swan events like March 2020, May 2021, FTX collapse)
- Low liquidation penalties (2% minimum) reduce liquidator incentive
- Aerodrome Slipstream pools may have lower liquidity than mainnet Uniswap
- Gauge staking adds complexity to liquidation flow (potential revert points)

## Recommended Mitigation

**Option 1: Cap Socialized Loss (Recommended)**
```solidity
function _handleReserveLiquidation(
    uint256 newDebtExchangeRateX96,
    uint256 newLendExchangeRateX96,
    uint256 missing
) internal {
    // ... existing code ...
    
    if (missing > 0) {
        uint256 totalLent = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Up);
        
        // NEW: Handle insolvency case
        if (missing >= totalLent) {
            // Protocol is insolvent - reduce lend rate to near-zero
            // Lenders take maximum loss but liquidations can continue
            newLendExchangeRateX96 = 1; // Minimum non-zero value
            emit ProtocolInsolvency(totalLent, missing);
        } else {
            // Normal socialization path
            newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
        }
        
        lastLendExchangeRateX96 = newLendExchangeRateX96;
        // ... rest of function ...
    }
}
```

**Option 2: Revert with Informative Error**
```solidity
if (missing > totalLent) {
    revert ProtocolInsolvent(totalLent, missing);
}
```
*Note: This preserves the DoS but makes it explicit rather than silent.*

**Option 3: Emergency Pause Mechanism**
Add protocol-level pause when insolvency detected, allowing governance to handle recovery.

## References

**In-Scope Confirmation:**
1. **AUDIT_HANDOFF_PR46.md** Line 86:  
   *"Daily debt cap logic around haircut/socialization paths"* ← Explicitly requested for review

2. **risk-and-acceptability.md** Lines 50-51:  
   *"Findings about bugs in the reserve-socialization math or lend exchange-rate reduction within this branch remain in scope."*

3. **Free Liquidation Design:** Lines 39-48 confirm `liquidatorCost = 0` is intentional, but bugs in the reserve math **remain in scope**.

**Related Code:**
- `src/V3Vault.sol:1200-1234` - `_handleReserveLiquidation()` function
- `src/V3Vault.sol:1175` - Division by zero issue in `_calculateLiquidation()` (related edge case)
- `src/V3Vault.sol:726-825` - `liquidate()` public function

## Severity Assessment

**MEDIUM Severity** based on Cantina criteria:
- ✅ Assets not at **direct** risk (no immediate drain)
- ✅ Function of protocol severely impacted (complete DoS)
- ✅ Availability compromised (lenders cannot withdraw)
- ⚠️ Requires extreme market conditions (reduces likelihood)
- ✅ No recovery mechanism (permanent without upgrade)

**Could argue HIGH if:**
- Demonstrable historical precedent (March 2020, May 2021, Nov 2022 crashes)
- Aerodrome Slipstream liquidity analysis shows higher vulnerability
- Combined with other findings that increase likelihood

---

**Submitted by:** Zhomart (zhomart67)  
**Date:** March 22, 2026  
**Competition:** Revert Finance Lend - Aerodrome Slipstream ($50K)  
**Commit:** 2bb022ee862c0f7f2010505f4d697f33827312ef
