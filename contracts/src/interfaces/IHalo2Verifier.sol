// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice EZKL-generated Halo2 verifier. Generated verifiers revert (rather than return false) on most failures.
interface IHalo2Verifier {
    function verifyProof(bytes calldata proof, uint256[] calldata instances) external returns (bool);
}
