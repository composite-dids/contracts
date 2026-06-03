// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./beaconverify.sol";

/// @title BeaconIdentityVerifier
/// @notice Turns BeaconStakeVerifier's "this validator exists" proof into a real
///         identity proof by *binding* it to an address that the caller controls.
///
///         The base contract recovers the validator's withdrawal (execution) address
///         from its 0x01/0x02 withdrawal credentials. On its own that proves nothing
///         about who is submitting it — anyone can replay anyone's proof. Here we
///         additionally require control of that withdrawal address, two ways:
///
///           1. verifyAndBind()        — require msg.sender == withdrawalAddr.
///                                       The tx signature already authenticates the
///                                       caller, so this is the simplest binding.
///           2. verifyWithSignature()  — caller may be a relayer; the *signature*
///                                       over a domain-separated message must recover
///                                       to withdrawalAddr. Enables gasless / delegated
///                                       submission.
///
///         Only the boolean signal + minimal metadata is stored — never the proof.
contract BeaconIdentityVerifier is BeaconStakeVerifier {
    // ---- identity registry ----
    mapping(address => bool) public isVerified;
    mapping(address => uint64) public effectiveBalanceGweiOf;
    // Sybil resistance: a given validator can back exactly one identity.
    mapping(uint40 => address) public boundIdentityOf;
    // Replay protection for the signature path (per signer).
    mapping(address => uint256) public nonces;

    event IdentityVerified(
        address indexed account,
        uint40 indexed validatorIndex,
        uint64 effectiveBalanceGwei,
        uint8 credsType
    );

    constructor(uint256 beaconStateTreeDepth) BeaconStakeVerifier(beaconStateTreeDepth) {}

    // ---------------------------------------------------------------------
    // Path 1: direct — msg.sender must be the withdrawal address.
    // ---------------------------------------------------------------------
    function verifyAndBind(
        uint256 beaconTimestamp,
        uint40 validatorIndex,
        bytes32[8] calldata validatorFields,
        bytes32[] calldata validatorProof,
        bytes32 beaconStateRoot,
        bytes32[] calldata stateRootProof
    ) external {
        ValidatorInfo memory info = _proveValidator(
            beaconTimestamp, validatorIndex, validatorFields, validatorProof, beaconStateRoot, stateRootProof
        );
        _requireBindable(info);
        require(msg.sender == info.withdrawalAddr, "caller is not withdrawal addr");
        _bind(info.withdrawalAddr, validatorIndex, info);
    }

    // ---------------------------------------------------------------------
    // Path 2: signature — withdrawal address signs, anyone may submit.
    // ---------------------------------------------------------------------
    /// @param nonce  Must equal nonces[withdrawalAddr]; read it on-chain first.
    /// @param signature  EIP-191 personal_sign over identityMessageHash(...).
    function verifyWithSignature(
        uint256 beaconTimestamp,
        uint40 validatorIndex,
        bytes32[8] calldata validatorFields,
        bytes32[] calldata validatorProof,
        bytes32 beaconStateRoot,
        bytes32[] calldata stateRootProof,
        uint256 nonce,
        bytes calldata signature
    ) external {
        ValidatorInfo memory info = _proveValidator(
            beaconTimestamp, validatorIndex, validatorFields, validatorProof, beaconStateRoot, stateRootProof
        );
        _requireBindable(info);

        address claimed = info.withdrawalAddr;
        require(nonce == nonces[claimed], "bad nonce");

        bytes32 digest = _prefixed(identityMessageHash(claimed, validatorIndex, nonce));
        require(_recover(digest, signature) == claimed, "bad signature");

        nonces[claimed]++;
        _bind(claimed, validatorIndex, info);
    }

    /// @notice The message a withdrawal address signs to prove control off-chain.
    ///         Domain-separated by chainid + this contract so a signature can't be
    ///         replayed on another chain or another deployment.
    function identityMessageHash(
        address account,
        uint40 validatorIndex,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                "BeaconIdentity",
                block.chainid,
                address(this),
                account,
                validatorIndex,
                nonce
            )
        );
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------
    function _requireBindable(ValidatorInfo memory info) internal pure {
        require(info.exists, "no proof");
        // Need an execution-layer address to bind to. 0x00 (BLS) creds have none.
        require(info.credsType == 0x01 || info.credsType == 0x02, "no exec withdrawal addr");
        require(info.withdrawalAddr != address(0), "zero withdrawal addr");
        require(!info.exited, "validator exited");
        require(info.effectiveBalanceGwei > 0, "zero balance");
    }

    function _bind(address account, uint40 validatorIndex, ValidatorInfo memory info) internal {
        address prior = boundIdentityOf[validatorIndex];
        require(prior == address(0) || prior == account, "validator already bound");

        boundIdentityOf[validatorIndex] = account;
        isVerified[account] = true;
        effectiveBalanceGweiOf[account] = info.effectiveBalanceGwei;

        emit IdentityVerified(account, validatorIndex, info.effectiveBalanceGwei, info.credsType);
    }

    function _prefixed(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "bad sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "bad v");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "ecrecover failed");
        return signer;
    }
}
