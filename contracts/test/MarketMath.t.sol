// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketMath} from "../src/lib/MarketMath.sol";

contract MarketMathTest is Test {
    function test_Log1e18_Precision() public pure {
        // ln(0.5) = -0.6931471805599453
        assertApproxEqAbs(MarketMath.log1e18(0.5e18), -0.6931471805599453e18, 1e9);
        // ln(0.9) = -0.10536051565782628
        assertApproxEqAbs(MarketMath.log1e18(9e17), -0.10536051565782628e18, 1e9);
        // ln(0.01) = -4.605170185988091
        assertApproxEqAbs(MarketMath.log1e18(1e16), -4.605170185988091e18, 1e9);
        // ln(1e-9) = -20.72326583694641
        assertApproxEqAbs(MarketMath.log1e18(1e9), -20.723265836946411e18, 1e9);
    }
}
