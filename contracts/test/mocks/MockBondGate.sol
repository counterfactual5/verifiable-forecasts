// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBondGate} from "../../src/interfaces/IBondGate.sol";

contract MockBondGate is IBondGate {
    mapping(uint256 => bool) public isBonded;

    function setBonded(uint256 modelId, bool bonded) external {
        isBonded[modelId] = bonded;
    }
}
