// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BeaconStakeVerifier
/// @notice Proves on-chain that a beacon-chain validator exists in a recent beacon
///         state, and recovers its withdrawal (execution) address + effective balance.
///         This is the native-staking analogue of "does address X have stake".
///
/// @dev Root of trust: EIP-4788 (Dencun). The beacon-roots contract exposes the
///      parent beacon block root for a given timestamp, from a ring buffer of
///      HISTORY_BUFFER_LENGTH = 8191 slots (~27 hours). Anything older is unreachable.
///
///      Proof path (leaf -> root):
///        Validator container  --(8-field tree, depth 3)-->  validatorRoot
///        validatorRoot        --(list depth 40 + 1 length mixin + state tree)--> beaconStateRoot
///        beaconStateRoot      --(block tree, depth 3, field 3)--> beaconBlockRoot
///
///      *** HASHING IS SHA-256, NOT KECCAK. *** SSZ merkleizes with SHA-256.
///
///      *** FORK SENSITIVITY ***  The constants below are for DENEB. At ELECTRA
///      (Pectra) the BeaconState field count crossed 32, so its tree depth went
///      5 -> 6, which changes BEACON_STATE_TREE_DEPTH and therefore the combined
///      validator generalized index. `validators` stays at field index 11 and the
///      Validator container is unchanged, but you MUST match these constants to the
///      fork your proof was generated against, or verification silently fails.
contract BeaconStakeVerifier {
    // EIP-4788 system contract.
    address constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    // FAR_FUTURE_EPOCH: exit_epoch == this means the validator has NOT exited.
    uint64 constant FAR_FUTURE_EPOCH = type(uint64).max;

    // ---- SSZ layout constants (DENEB) ----
    // BeaconBlock: 5 fields -> depth 3; state_root is field 3.
    uint256 constant STATE_ROOT_INDEX_IN_BLOCK = 3;
    uint256 constant BLOCK_TREE_DEPTH = 3;

    // BeaconState (Deneb): 28 fields -> depth 5. `validators` is field 11.
    // ELECTRA: 37 fields -> depth 6. The field count crossing 32 bumped the depth.
    //
    // Because this changes per fork, it is an immutable set at construction time
    // instead of a hardcoded constant. Deploy one instance per fork:
    //   Deneb   -> BEACON_STATE_TREE_DEPTH = 5
    //   Electra -> BEACON_STATE_TREE_DEPTH = 6   (current mainnet)
    // The proof service reports which value to use (validatorProof.length - 41).
    uint256 public immutable BEACON_STATE_TREE_DEPTH;
    uint256 constant VALIDATORS_FIELD_INDEX = 11;

    /// @param beaconStateTreeDepth SSZ merkle depth of the BeaconState container
    ///        for the fork your proofs target (Deneb = 5, Electra = 6).
    constructor(uint256 beaconStateTreeDepth) {
        require(beaconStateTreeDepth >= 5 && beaconStateTreeDepth <= 8, "bad state depth");
        BEACON_STATE_TREE_DEPTH = beaconStateTreeDepth;
    }

    // validators: List[Validator, 2**40]. Tree depth 40, +1 for the length mixin.
    uint256 constant VALIDATOR_LIST_DEPTH = 40;

    // Validator container: 8 fields -> depth 3.
    // field 0 = pubkey (htr), 1 = withdrawal_credentials, 2 = effective_balance,
    // 3 = slashed, ... 6 = exit_epoch, 7 = withdrawable_epoch.
    uint256 constant VALIDATOR_TREE_DEPTH = 3;
    uint256 constant FIELD_WITHDRAWAL_CREDS = 1;
    uint256 constant FIELD_EFFECTIVE_BALANCE = 2;
    uint256 constant FIELD_EXIT_EPOCH = 6;

    struct ValidatorInfo {
        bool exists;             // proof verified against a real beacon root
        address withdrawalAddr;  // 0x0 if creds are 0x00-type (BLS, no exec address)
        uint8 credsType;         // 0x00 / 0x01 / 0x02
        uint64 effectiveBalanceGwei;
        bool exited;             // exit_epoch != FAR_FUTURE_EPOCH
    }

    /// @notice Prove a validator's stake/identity against a recent beacon state.
    /// @param beaconTimestamp   Timestamp identifying the EL block whose *parent*
    ///                          beacon block root anchors the proof (EIP-4788 semantics).
    /// @param validatorIndex    The validator's index in the registry (< 2**40).
    /// @param validatorFields   The 8 leaves of the Validator container (computed
    ///                          off-chain; field 0 is htr(pubkey), not the raw pubkey).
    /// @param validatorProof    SSZ branch: validatorRoot -> beaconStateRoot.
    ///                          Length must be VALIDATOR_LIST_DEPTH + 1 + BEACON_STATE_TREE_DEPTH.
    /// @param beaconStateRoot   Claimed beacon state root (verified below).
    /// @param stateRootProof    SSZ branch: beaconStateRoot -> beaconBlockRoot.
    ///                          Length must be BLOCK_TREE_DEPTH.
    function proveValidator(
        uint256 beaconTimestamp,
        uint40 validatorIndex,
        bytes32[8] calldata validatorFields,
        bytes32[] calldata validatorProof,
        bytes32 beaconStateRoot,
        bytes32[] calldata stateRootProof
    ) external view returns (ValidatorInfo memory info) {
        return _proveValidator(
            beaconTimestamp, validatorIndex, validatorFields, validatorProof, beaconStateRoot, stateRootProof
        );
    }

    /// @dev Internal core so subclasses (e.g. identity binding) can reuse the proof
    ///      verification without re-implementing it.
    function _proveValidator(
        uint256 beaconTimestamp,
        uint40 validatorIndex,
        bytes32[8] calldata validatorFields,
        bytes32[] calldata validatorProof,
        bytes32 beaconStateRoot,
        bytes32[] calldata stateRootProof
    ) internal view returns (ValidatorInfo memory info) {
        // 1. Fetch the trusted root from EIP-4788.
        bytes32 beaconBlockRoot = _beaconBlockRoot(beaconTimestamp);

        // 2. beaconStateRoot must sit at field 3 of the BeaconBlock tree.
        require(stateRootProof.length == BLOCK_TREE_DEPTH, "bad stateRootProof len");
        require(
            _verifyBranch(beaconStateRoot, stateRootProof, STATE_ROOT_INDEX_IN_BLOCK, beaconBlockRoot),
            "state root proof failed"
        );

        // 3. Reconstruct the validator container root from its 8 fields.
        bytes32 validatorRoot = _merkleizeValidator(validatorFields);

        // 4. Verify validatorRoot at validatorIndex within validators[] within state.
        //    Combined leaf index (LSB-first, leaf->root):
        //      low  (VALIDATOR_LIST_DEPTH+1) bits  = validatorIndex  (bit 40 = 0 => data subtree side of the length mixin)
        //      high (BEACON_STATE_TREE_DEPTH) bits = VALIDATORS_FIELD_INDEX
        uint256 expectedLen = VALIDATOR_LIST_DEPTH + 1 + BEACON_STATE_TREE_DEPTH;
        require(validatorProof.length == expectedLen, "bad validatorProof len");
        uint256 combinedIndex =
            uint256(validatorIndex) |
            (VALIDATORS_FIELD_INDEX << (VALIDATOR_LIST_DEPTH + 1));
        require(
            _verifyBranch(validatorRoot, validatorProof, combinedIndex, beaconStateRoot),
            "validator proof failed"
        );

        // 5. Decode the fields we care about.
        bytes32 creds = validatorFields[FIELD_WITHDRAWAL_CREDS];
        info.exists = true;
        info.credsType = uint8(uint256(creds) >> 248);                 // first byte
        info.withdrawalAddr = address(uint160(uint256(creds)));        // last 20 bytes
        info.effectiveBalanceGwei = _le64(validatorFields[FIELD_EFFECTIVE_BALANCE]);
        info.exited = _le64(validatorFields[FIELD_EXIT_EPOCH]) != FAR_FUTURE_EPOCH;
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------

    /// @dev Query EIP-4788 for the parent beacon block root at `timestamp`.
    function _beaconBlockRoot(uint256 timestamp) internal view returns (bytes32 root) {
        (bool ok, bytes memory out) = BEACON_ROOTS.staticcall(abi.encode(timestamp));
        require(ok && out.length == 32, "4788 lookup failed");
        root = abi.decode(out, (bytes32));
        require(root != bytes32(0), "no root for timestamp");
    }

    /// @dev Generic SSZ-style branch check. `index` is the leaf's position within
    ///      its tree (LSB = level nearest the leaf). Uses SHA-256, per SSZ.
    function _verifyBranch(
        bytes32 leaf,
        bytes32[] calldata branch,
        uint256 index,
        bytes32 root
    ) internal view returns (bool) {
        bytes32 node = leaf;
        for (uint256 i = 0; i < branch.length; i++) {
            if ((index >> i) & 1 == 1) {
                node = sha256(abi.encodePacked(branch[i], node)); // sibling on the left
            } else {
                node = sha256(abi.encodePacked(node, branch[i])); // sibling on the right
            }
        }
        return node == root;
    }

    /// @dev Merkleize the 8 Validator container leaves into its hash tree root.
    function _merkleizeValidator(bytes32[8] calldata f) internal view returns (bytes32) {
        bytes32 a0 = sha256(abi.encodePacked(f[0], f[1]));
        bytes32 a1 = sha256(abi.encodePacked(f[2], f[3]));
        bytes32 a2 = sha256(abi.encodePacked(f[4], f[5]));
        bytes32 a3 = sha256(abi.encodePacked(f[6], f[7]));
        bytes32 b0 = sha256(abi.encodePacked(a0, a1));
        bytes32 b1 = sha256(abi.encodePacked(a2, a3));
        return sha256(abi.encodePacked(b0, b1));
    }

    /// @dev SSZ encodes uint64 little-endian in the first 8 bytes of a 32-byte chunk.
    function _le64(bytes32 chunk) internal pure returns (uint64 v) {
        // byte 0 of the chunk is the LSB.
        for (uint256 i = 0; i < 8; i++) {
            v |= uint64(uint8(chunk[i])) << (8 * uint64(i));
        }
    }
}
