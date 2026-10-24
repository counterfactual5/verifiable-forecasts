// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Stand-in for an EZKL verifier: accepts exactly one proof on exactly one instance vector and
///      reverts otherwise, as generated verifiers do.
contract InstanceVerifier {
    bytes32 public immutable proofHash;
    bytes32 public immutable instancesHash;

    constructor(bytes memory proof, uint256[] memory instances) {
        proofHash = keccak256(proof);
        instancesHash = keccak256(abi.encode(instances));
    }

    function verifyProof(bytes calldata proof, uint256[] calldata instances) external view returns (bool) {
        require(keccak256(proof) == proofHash && keccak256(abi.encode(instances)) == instancesHash);
        return true;
    }
}
