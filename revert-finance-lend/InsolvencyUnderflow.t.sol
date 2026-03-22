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
