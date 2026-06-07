// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SoulboundToken.sol";

interface ISignalVerifier {
    /// Verify `proofData` for `claimant` and return the readable identity handle
    /// (e.g. GitHub username, email, first paper title, or the account address for
    /// balance). MUST revert if the proof is invalid or not bound to `claimant`.
    function verifyAndGetWitness(address claimant, bytes calldata proofData)
        external
        view
        returns (string memory handle);
}

/// @title DIDRegistry
/// @notice Composite decentralised-identity registration in a SINGLE transaction.
///         A configurable boolean **mechanism** (negation-free DNF) decides which
///         identity signals are required. To register, the caller submits the proofs for
///         one satisfied term; the registry, atomically:
///           1. verifies each proof via that signal's verifier (`verifyAndGetWitness`),
///              which returns the readable identity and reverts on an invalid/unbound proof;
///           2. de-duplicates against an on-chain hashtable — reusing an identity already
///              registered for a signal (same GitHub handle, paper title, address, …) reverts;
///           3. records each identity and mints one soulbound credential.
///         If anything fails, the whole transaction reverts and nothing is recorded.
///
///         Signals (default set): 0 balance · 1 GitHub · 2 Google · 3 arXiv.
///         Mechanism examples: [0b1111] = all four; [0b0011,0b1100] = (balance AND github) OR (google AND arxiv).
contract DIDRegistry is SoulboundToken {
    uint8 public constant MAX_SIGNALS = 8;

    address[] public verifiers; // signal slot => verifier (implements ISignalVerifier)
    uint8[] public terms;       // DNF: eligibility == OR of these AND-term bitmaps
    address public owner;

    /// @notice On-chain de-dup hashtable: signal => keccak(handle) => first registrant.
    mapping(uint8 => mapping(bytes32 => address)) public registrantOf;
    /// @notice The readable identity stored per (signal, key) — queryable on-chain.
    mapping(uint8 => mapping(bytes32 => string)) public handleOfKey;
    /// @notice Bitmap of signals an account registered (bit i == signal i).
    mapping(address => uint8) public registeredSignalsOf;

    event Registered(address indexed account, uint8 indexed termIndex, uint8 termMask, uint256 tokenId);
    event SignalRegistered(uint8 indexed signal, bytes32 indexed key, string handle, address indexed registrant);
    event VerifierSet(uint8 indexed slot, address verifier);
    event MechanismSet(uint8[] terms);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param verifiers_   Signal verifiers (length n, 1..MAX_SIGNALS), each ISignalVerifier.
    /// @param initialTerms DNF term bitmaps; each non-zero and referencing only configured signals.
    constructor(address[] memory verifiers_, uint8[] memory initialTerms)
        SoulboundToken("Decentralised Identity Credential", "DID")
    {
        uint256 n = verifiers_.length;
        require(n >= 1 && n <= MAX_SIGNALS, "bad signal count");
        for (uint256 s = 0; s < n; s++) {
            require(verifiers_[s] != address(0), "zero verifier");
            verifiers.push(verifiers_[s]);
            emit VerifierSet(uint8(s), verifiers_[s]);
        }
        _setMechanism(initialTerms, n);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---- admin ----
    function setMechanism(uint8[] calldata newTerms) external onlyOwner {
        _setMechanism(newTerms, verifiers.length);
    }

    function _setMechanism(uint8[] memory newTerms, uint256 n) internal {
        require(newTerms.length >= 1, "no terms");
        uint8 full = n == 8 ? 0xff : uint8((uint256(1) << n) - 1);
        delete terms;
        for (uint256 i = 0; i < newTerms.length; i++) {
            uint8 t = newTerms[i];
            require(t != 0, "empty term");
            require((t & ~full) == 0, "term references missing signal");
            terms.push(t);
        }
        emit MechanismSet(terms);
    }

    function setVerifier(uint8 slot, address verifier) external onlyOwner {
        require(slot < verifiers.length, "bad slot");
        require(verifier != address(0), "zero verifier");
        verifiers[slot] = verifier;
        emit VerifierSet(slot, verifier);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---- views ----
    function numSignals() external view returns (uint256) {
        return verifiers.length;
    }

    function termCount() external view returns (uint256) {
        return terms.length;
    }

    /// @notice Decompose a term into the signal slots it requires.
    function termSignals(uint256 termIndex) external view returns (uint8[] memory out) {
        require(termIndex < terms.length, "bad term");
        uint8 mask = terms[termIndex];
        uint256 n = verifiers.length;
        uint256 c;
        for (uint256 s = 0; s < n; s++) if (mask & (uint8(1) << uint8(s)) != 0) c++;
        out = new uint8[](c);
        uint256 j;
        for (uint256 s = 0; s < n; s++) if (mask & (uint8(1) << uint8(s)) != 0) out[j++] = uint8(s);
    }

    /// @notice Has this exact identity (`handle`) already registered signal `slot`?
    function isHandleUsed(uint8 slot, string calldata handle) external view returns (bool) {
        return registrantOf[slot][keccak256(bytes(handle))] != address(0);
    }

    function isRegistered(address account) external view returns (bool) {
        return balanceOf(account) != 0;
    }

    // ---- registration (one transaction) ----

    /// @notice Register by satisfying term `termIndex`. `proofs[k]` is the proof for the
    ///         k-th signal of the term in ascending signal order, each ABI-encoded as that
    ///         verifier expects. Verifies all proofs, blocks any reused identity, records
    ///         the identities, and mints one soulbound credential — atomically.
    function register(uint8 termIndex, bytes[] calldata proofs) external returns (uint256 tokenId) {
        require(termIndex < terms.length, "bad term");
        uint8 mask = terms[termIndex];

        uint256 n = verifiers.length;
        uint256 j = 0;
        uint8 registered = 0;
        for (uint256 s = 0; s < n; s++) {
            if ((mask & (uint8(1) << uint8(s))) == 0) continue;
            require(j < proofs.length, "missing proof");

            // Verify the proof for THIS caller; returns the readable identity or reverts.
            string memory handle = ISignalVerifier(verifiers[s]).verifyAndGetWitness(msg.sender, proofs[j++]);
            require(bytes(handle).length > 0, "empty handle");

            // De-dup: this identity must not already be registered for this signal.
            bytes32 key = keccak256(bytes(handle));
            require(registrantOf[uint8(s)][key] == address(0), "signal identity already used");

            registrantOf[uint8(s)][key] = msg.sender;
            handleOfKey[uint8(s)][key] = handle;
            registered |= uint8(1) << uint8(s);
            emit SignalRegistered(uint8(s), key, handle, msg.sender);
        }
        require(j == proofs.length, "extra proofs");

        registeredSignalsOf[msg.sender] |= registered;
        tokenId = _mint(msg.sender);
        emit Registered(msg.sender, termIndex, mask, tokenId);
    }
}
