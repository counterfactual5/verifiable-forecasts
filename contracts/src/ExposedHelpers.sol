// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseFeeMarket} from "./BaseFeeMarket.sol";

/// @dev Test-only exposure of internal log math for precision assertions.
contract ExposedHelpers is BaseFeeMarket {
    constructor(BaseFeeMarket m) BaseFeeMarket(m.token(), m.feeBps()) {}

    function exposed_log1e18(uint256 x) external pure returns (int256) {
        return log1e18(x);
    }
}
