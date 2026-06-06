// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SoulboundToken.sol";

/// @title DIDRegistry
/// @notice Decentralised-identity registration with built-in de-duplication.
///
///         A user "registers" by aggregating one or more identity *signals* that
///         already live in other verifier contracts (e.g. `BeaconIdentityVerifier`
///         and `HistoricalBalanceVerifier`). This contract:
///
///           1. confirms the signals on-chain by calling those verifier contracts,
///           2. de-duplicates so the *same* proof can register only once, and
///           3. issues one non-transferable credential (SBT) per identity.
///
///         === The (x, r', π) registration scheme ===
///         De-duplication is enforced with an append-only (incremental) Merkle tree
///         of identity commitments, plus a `used` set. To register, the caller submits:
///
///           x   = the identity commitment (a deterministic hash of their verified
///                 signals — see `previewCommitment`); the new leaf to append.
///           r'  = `newRoot`, the Merkle root the tree should have *after* x is appended.
///           π   = `insertionPath`, the sibling hashes along x's path.
///
///         The current root `r` (`root()`) is public and known. The contract checks,
///         against `r`, that (a) the next free leaf is currently empty and (b) inserting
///         x along π yields exactly r'. Both checks are bound by Merkle collision
///         resistance, so a valid (x, r', π) is the *unique* honest append. The new root
///         r' is committed and remembered (`isKnownRoot`) so later membership proofs of
///         x against any historical root remain verifiable.
///
///         Because the same verified signal-set always hashes to the same x, replaying
///         "exactly the same proof" hits the `used` set and is rejected.
///
///         === Signals & room for more ===
///         Up to 4 signal slots are supported. Slots 0 and 1 are wired to the two
///         existing verifiers at deploy time. Slots 2 and 3 are reserved for the third
///         and fourth proofs and default to the empty source `address(0)` — treated as
///         the `0x0000` placeholder until the owner wires them up via `setSignalSource`.
///
///         === Account uniqueness (one witness = one account) ===
///         Every signal binds an underlying *witness* (a validator index, a balance
///         account, a zkTLS nullifier, …) to exactly one account — and each source
///         verifier enforces that itself (e.g. BeaconIdentityVerifier.boundIdentityOf,
///         Reclaim's usedNullifier). This registry relies on that: it only ever reads
///         the signals of `msg.sender`, so a registration can only aggregate signals
///         that all belong to the *same* account. It cannot combine proofs from two
///         different accounts, and the witness's global uniqueness is inherited from
///         the source contract. Any signal added in slot 2/3 MUST provide the same
///         one-witness-one-account guarantee for this property to hold.
contract DIDRegistry is SoulboundToken {
    // -----------------------------------------------------------------
    // Signal sources
    // -----------------------------------------------------------------

    /// @dev A signal source is an external verifier exposing a
    ///      `someAccessor(address) view returns (bool)`. We store the address and the
    ///      4-byte selector so heterogeneous verifiers (e.g. `isVerified` vs
    ///      `isEligible`) can be queried uniformly.
    struct SignalSource {
        address verifier;
        bytes4 selector;
    }

    uint8 public constant MAX_SIGNALS = 4;
    SignalSource[MAX_SIGNALS] public signals;

    address public owner;

    event SignalSourceSet(uint8 indexed slot, address verifier, bytes4 selector);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // -----------------------------------------------------------------
    // Incremental Merkle tree (de-duplication accumulator)
    // -----------------------------------------------------------------

    /// @dev Domain tag mixed into every commitment so leaves can't be replayed across
    ///      chains or deployments.
    bytes32 public constant DOMAIN = keccak256("DIDRegistry.v1");

    uint256 public immutable TREE_DEPTH;
    /// @notice Current Merkle root `r` (public & known to clients building π).
    bytes32 public root;
    /// @notice Index the next appended leaf will occupy.
    uint256 public nextIndex;

    /// @dev Precomputed roots of all-zero subtrees: zeros[i] = root of an empty
    ///      subtree of height i. zeros[0] is the empty-leaf value.
    bytes32[] internal _zeros;

    /// @notice Every root the tree has ever had (including the empty-tree root) is
    ///         "known", so membership proofs against historical roots stay valid.
    mapping(bytes32 => bool) public isKnownRoot;

    /// @notice Identity commitments that have already registered (de-dup set).
    mapping(bytes32 => bool) public usedCommitment;

    /// @notice The credential id minted for a given commitment (0 = not registered).
    mapping(bytes32 => uint256) public tokenOfCommitment;

    /// @notice The union of every signal bitmap an account has ever registered.
    mapping(address => uint8) public signalsOf;

    event Registered(
        address indexed account,
        bytes32 indexed commitment,
        uint256 leafIndex,
        uint8 signalBitmap,
        bytes32 newRoot,
        uint256 tokenId
    );

    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    /// @param treeDepth        Merkle tree depth; capacity is 2**treeDepth identities.
    /// @param initialVerifiers Up to MAX_SIGNALS source addresses. Use `address(0)`
    ///                         for a reserved/unused slot (the `0x0000` placeholder).
    /// @param initialSelectors The accessor selector for each source, e.g.
    ///                         `bytes4(keccak256("isVerified(address)"))`.
    constructor(
        uint256 treeDepth,
        address[MAX_SIGNALS] memory initialVerifiers,
        bytes4[MAX_SIGNALS] memory initialSelectors
    ) SoulboundToken("Decentralised Identity Credential", "DID") {
        require(treeDepth >= 1 && treeDepth <= 32, "bad tree depth");
        TREE_DEPTH = treeDepth;

        // Precompute zero subtree roots and the empty-tree root.
        _zeros.push(bytes32(0)); // zeros[0] = empty leaf
        for (uint256 i = 0; i < treeDepth; i++) {
            _zeros.push(_hashPair(_zeros[i], _zeros[i]));
        }
        root = _zeros[treeDepth];
        isKnownRoot[root] = true;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        for (uint8 s = 0; s < MAX_SIGNALS; s++) {
            if (initialVerifiers[s] != address(0)) {
                signals[s] = SignalSource(initialVerifiers[s], initialSelectors[s]);
                emit SignalSourceSet(s, initialVerifiers[s], initialSelectors[s]);
            }
        }
    }

    // -----------------------------------------------------------------
    // Admin: wire up additional signals (slots 2 & 3 reserved for proof 3 & 4)
    // -----------------------------------------------------------------

    function setSignalSource(uint8 slot, address verifier, bytes4 selector) external onlyOwner {
        require(slot < MAX_SIGNALS, "bad slot");
        signals[slot] = SignalSource(verifier, selector);
        emit SignalSourceSet(slot, verifier, selector);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // -----------------------------------------------------------------
    // Signal reading
    // -----------------------------------------------------------------

    /// @notice Returns whether `account` currently satisfies the signal in `slot`.
    ///         An unconfigured slot (verifier == 0) is always false (placeholder).
    function hasSignal(uint8 slot, address account) public view returns (bool) {
        if (slot >= MAX_SIGNALS) return false;
        SignalSource memory src = signals[slot];
        if (src.verifier == address(0)) return false;
        (bool ok, bytes memory ret) =
            src.verifier.staticcall(abi.encodeWithSelector(src.selector, account));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @notice The bitmap of signals `account` currently holds (bit i == slot i).
    function signalBitmapOf(address account) public view returns (uint8 bitmap) {
        for (uint8 s = 0; s < MAX_SIGNALS; s++) {
            if (hasSignal(s, account)) bitmap |= uint8(1) << s;
        }
    }

    /// @notice The identity commitment `x` for (account, bitmap). Deterministic, so the
    ///         same verified signal-set always yields the same leaf (enabling de-dup).
    function previewCommitment(address account, uint8 bitmap) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, block.chainid, address(this), account, bitmap));
    }

    // -----------------------------------------------------------------
    // Registration  —  submit (x, r', π)
    // -----------------------------------------------------------------

    /// @notice Register `msg.sender`'s aggregated identity.
    /// @param signalBitmap  The signal-set the caller claims (must match on-chain state).
    ///                      Defines the leaf x = previewCommitment(caller, signalBitmap).
    /// @param newRoot       r' — the Merkle root after x is appended.
    /// @param insertionPath π — sibling hashes along x's path (length == TREE_DEPTH).
    /// @return tokenId   The freshly minted soulbound credential id for this proof.
    /// @return leafIndex The tree position x was appended at.
    ///
    ///         Each distinct proof registers exactly once (the `used` set blocks exact
    ///         replays); presenting a *new* proof (a different signal-set) mints a new
    ///         credential, so an account can accumulate several over time.
    function register(
        uint8 signalBitmap,
        bytes32 newRoot,
        bytes32[] calldata insertionPath
    ) external returns (uint256 tokenId, uint256 leafIndex) {
        // 1. The claimed signal-set must match what the verifier contracts say now.
        require(signalBitmap != 0, "no signals");
        require(signalBitmap == signalBitmapOf(msg.sender), "signal mismatch");

        // 2. Derive the leaf x and reject exact-duplicate proofs.
        bytes32 commitment = previewCommitment(msg.sender, signalBitmap);
        require(!usedCommitment[commitment], "already registered");

        // 3. Verify & perform the append: (x, r', π) against the public root r.
        leafIndex = _verifiedInsert(commitment, newRoot, insertionPath);

        // 4. Record and mint a fresh credential for this proof.
        usedCommitment[commitment] = true;
        signalsOf[msg.sender] |= signalBitmap;
        tokenId = _mint(msg.sender);
        tokenOfCommitment[commitment] = tokenId;

        emit Registered(msg.sender, commitment, leafIndex, signalBitmap, newRoot, tokenId);
    }

    // -----------------------------------------------------------------
    // Incremental Merkle internals
    // -----------------------------------------------------------------

    /// @dev Verifies that appending `leaf` at the next free index, using sibling path
    ///      `path`, transforms the current root `r` into `newRoot` (r'), then commits it.
    ///
    ///      Soundness: with `path` we recompute the root twice along the same branch —
    ///      once with the empty-leaf value (must equal the current root `r`, proving the
    ///      slot is empty and `path` is the genuine frontier) and once with `leaf` (must
    ///      equal `newRoot`). The index is taken from storage, never the caller.
    function _verifiedInsert(
        bytes32 leaf,
        bytes32 newRoot,
        bytes32[] calldata path
    ) internal returns (uint256 index) {
        index = nextIndex;
        require(index < (uint256(1) << TREE_DEPTH), "tree full");
        require(path.length == TREE_DEPTH, "bad path length");
        require(leaf != bytes32(0), "zero leaf");

        bytes32 emptyNode = _zeros[0]; // current value at `index`
        bytes32 filledNode = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            bytes32 sib = path[i];
            if (idx & 1 == 0) {
                emptyNode = _hashPair(emptyNode, sib);
                filledNode = _hashPair(filledNode, sib);
            } else {
                emptyNode = _hashPair(sib, emptyNode);
                filledNode = _hashPair(sib, filledNode);
            }
            idx >>= 1;
        }
        require(emptyNode == root, "stale root / bad path");
        require(filledNode == newRoot, "newRoot mismatch");

        root = newRoot;
        isKnownRoot[newRoot] = true;
        nextIndex = index + 1;
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    /// @notice Whether `account` holds at least one credential (has registered).
    function isRegistered(address account) external view returns (bool) {
        return balanceOf(account) != 0;
    }

    /// @notice The empty-subtree root at height `height` (clients building π need these).
    function zeros(uint256 height) external view returns (bytes32) {
        return _zeros[height];
    }
}
