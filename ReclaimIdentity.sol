// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal mirror of the Reclaim verifier's ABI. The Reclaim verifier is
///         already deployed on Sepolia at 0xAe94FB09711e1c6B057853a515483792d8e474d0,
///         so we do NOT import the @reclaimprotocol SDK (it pins an old solc, 0.8.4,
///         which conflicts with this codebase). We only need the struct layout to call
///         the deployed `verifyProof`, plus our own context parsing.
///
///         Trust model: `verifyProof` validates that the claim was signed by the
///         expected attestor/witness set for its epoch (it does NOT verify a zk proof
///         on-chain — the witness attestation IS the anchor). On top of that we add:
///           - provider binding  (this proof is for THIS provider, not another)
///           - user binding       (contextAddress == msg.sender; stops front-running)
///           - sybil nullifier    (one claim identifier verifies once)

struct ClaimInfo {
    string provider;
    string parameters;
    string context;
}

struct CompleteClaimData {
    bytes32 identifier;
    address owner;
    uint32 timestampS;
    uint32 epoch;
}

struct SignedClaim {
    CompleteClaimData claim;
    bytes[] signatures;
}

struct Proof {
    ClaimInfo claimInfo;
    SignedClaim signedClaim;
}

interface IReclaim {
    function verifyProof(Proof memory proof) external view;
}

/// @title ReclaimIdentity
/// @notice Base for "prove you control an off-chain account" via Reclaim zkTLS.
///         Subclasses fix the provider's extracted field (e.g. username / email).
abstract contract ReclaimIdentity {
    IReclaim public immutable reclaim;
    /// Provider binding: keccak of the expected providerHash string. Empty => skip.
    bytes32 private immutable expectedProviderHashKeccak;
    bool public immutable bindProvider;

    string public fieldKey; // context target, e.g. '"username":"' or '"email":"'
    string public kind;     // human label, e.g. "github"

    mapping(address => bool) public isVerified;
    mapping(address => string) public handleOf;    // extracted username / email
    mapping(bytes32 => bool) public usedNullifier; // sybil: one claim -> one use

    event IdentityVerified(address indexed account, string handle, bytes32 indexed nullifier);

    /// @param reclaimAddr        deployed Reclaim verifier (Sepolia: 0xAe94FB09711e1c6B057853a515483792d8e474d0)
    /// @param expectedProviderHash the provider's on-chain providerHash hex string;
    ///        pass "" to skip provider binding (relies on verifyProof + field presence).
    /// @param fieldKey_          the JSON target whose value is the account handle.
    /// @param kind_              label.
    constructor(
        address reclaimAddr,
        string memory expectedProviderHash,
        string memory fieldKey_,
        string memory kind_
    ) {
        reclaim = IReclaim(reclaimAddr);
        bindProvider = bytes(expectedProviderHash).length > 0;
        expectedProviderHashKeccak = keccak256(bytes(expectedProviderHash));
        fieldKey = fieldKey_;
        kind = kind_;
    }

    function submitProof(Proof calldata proof) external {
        // 1. Trust anchor: attestor/witness signatures. Reverts if invalid.
        reclaim.verifyProof(proof);

        string memory context = proof.claimInfo.context;

        // 2. Provider binding: ensure the proof is for THIS provider, not another.
        if (bindProvider) {
            string memory ph = _extract(context, '"providerHash":"');
            require(keccak256(bytes(ph)) == expectedProviderHashKeccak, "wrong provider");
        }

        // 3. User binding: the context address must be the caller. The frontend sets
        //    this via the SDK's addContext(wallet, ...). Prevents replay/front-running.
        address ctxAddr = _toAddress(_extract(context, '"contextAddress":"'));
        require(ctxAddr == msg.sender, "caller != context address");

        // 4. Sybil resistance: a given claim identifier can verify exactly once.
        bytes32 nullifier = keccak256(abi.encode(proof.signedClaim.claim.identifier));
        require(!usedNullifier[nullifier], "already used");
        usedNullifier[nullifier] = true;

        // 5. Extract the handle and record the signal.
        string memory handle = _extract(context, fieldKey);
        require(bytes(handle).length > 0, "handle not found");

        // 6. Subclass hook for extra claim checks (e.g. arXiv: >= N papers). No-op by default.
        _afterExtract(context, handle);

        isVerified[msg.sender] = true;
        handleOf[msg.sender] = handle;
        emit IdentityVerified(msg.sender, handle, nullifier);
    }

    /// @dev Override to add provider-specific checks on the proof context. Default no-op,
    ///      so GitHub/Google behave exactly as before.
    function _afterExtract(string memory context, string memory handle) internal view virtual {}

    /// @notice DIDRegistry signal accessor: a unique, account-independent witness for the
    ///         identity `account` proved (the hash of its handle), or 0 if not verified.
    ///         Same off-chain account => same witness, so it can't be reused across wallets.
    function identityWitness(address account) external view returns (bytes32) {
        if (!isVerified[account]) return bytes32(0);
        return keccak256(bytes(handleOf[account]));
    }

    /// @notice Stateless verifier entrypoint for one-transaction registration. Validates a
    ///         Reclaim proof bound to `claimant` and returns its readable identity handle
    ///         (e.g. the GitHub username / email / first paper title). Reverts if invalid.
    ///         `proofData` is `abi.encode(Proof)`. No state is written here — the registry
    ///         records the result and enforces de-duplication.
    function verifyAndGetWitness(address claimant, bytes calldata proofData)
        external
        view
        returns (string memory handle)
    {
        Proof memory proof = abi.decode(proofData, (Proof));
        reclaim.verifyProof(proof);

        string memory context = proof.claimInfo.context;
        if (bindProvider) {
            require(keccak256(bytes(_extract(context, '"providerHash":"'))) == expectedProviderHashKeccak, "wrong provider");
        }
        require(_toAddress(_extract(context, '"contextAddress":"')) == claimant, "caller != context address");

        handle = _extract(context, fieldKey);
        require(bytes(handle).length > 0, "handle not found");
        _afterExtract(context, handle);
    }

    // ---------------------------------------------------------------------
    // context parsing (ported from Reclaim's Claims.extractFieldFromContext)
    // ---------------------------------------------------------------------
    /// @dev Returns the value following `target` up to the next unescaped quote.
    function _extract(string memory data, string memory target)
        internal
        pure
        returns (string memory)
    {
        bytes memory d = bytes(data);
        bytes memory t = bytes(target);
        if (d.length < t.length) return "";

        uint256 start;
        bool found;
        for (uint256 i = 0; i <= d.length - t.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < t.length; j++) {
                if (d[i + j] != t[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                start = i + t.length;
                found = true;
                break;
            }
        }
        if (!found) return "";

        uint256 end = start;
        while (end < d.length && !(d[end] == '"' && d[end - 1] != "\\")) {
            end++;
        }
        if (end <= start || end >= d.length) return "";

        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = d[i];
        }
        return string(out);
    }

    /// @dev Parse a "0x…40hex" string into an address (case-insensitive).
    function _toAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42 && b[0] == "0" && (b[1] == "x" || b[1] == "X"), "bad addr");
        uint160 r;
        for (uint256 i = 2; i < 42; i++) {
            r = r * 16 + uint160(_hex(uint8(b[i])));
        }
        return address(r);
    }

    function _hex(uint8 c) private pure returns (uint8) {
        if (c >= 48 && c <= 57) return c - 48; // 0-9
        if (c >= 97 && c <= 102) return c - 87; // a-f
        if (c >= 65 && c <= 70) return c - 55; // A-F
        revert("bad hex");
    }
}
