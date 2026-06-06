// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SoulboundToken.sol";

/// @title DIDRegistry
/// @notice Composite decentralised-identity registration with a configurable boolean
///         **mechanism** over `n` identity signals, and per-signal **Sparse Merkle Tree**
///         de-duplication.
///
///         === Signals & witnesses ===
///         A signal is an external verifier exposing
///             `identityWitness(address account) view returns (bytes32)`
///         which returns a unique, account-independent *witness* for whatever the account
///         proved (a validator index, a GitHub username, an email, an arXiv id, …) or 0 if
///         the account has not proven that identity. The default integrated set is:
///
///           signal 0  validator   — BeaconIdentityVerifier
///           signal 1  GitHub       — GithubIdentity   (Reclaim zkTLS)
///           signal 2  Google/gmail — GoogleIdentity   (Reclaim zkTLS)
///           signal 3  arXiv        — ArxivIdentity    (Reclaim zkTLS)
///
///         === The mechanism (negation-free DNF) ===
///         Eligibility is a disjunction (OR) of conjunctive *terms*, each term a bitmap of
///         signals that must ALL hold (AND). This is a negation-free DNF, e.g.:
///
///           terms = [0b1111]                 => validator AND github AND gmail AND arxiv
///           terms = [0b0011, 0b1100]         => (validator AND github) OR (gmail AND arxiv)
///
///         To register, the caller names ONE term they satisfy and supplies, for every
///         signal in that term, an insertion proof for that signal's tree. The default
///         mechanism is a single all-AND term over every configured signal.
///
///         === Per-signal Sparse Merkle Tree (de-duplication) ===
///         Each signal owns a fixed-depth Sparse Merkle Tree keyed by the witness. The
///         contract stores ONLY the current root per signal. A leaf's position is the low
///         `TREE_DEPTH` bits of its key, so the *same* witness always maps to the same
///         leaf. To insert witness `w` into signal `s`'s tree the caller submits:
///
///           r'  = `newRoot`  — the tree's root after the leaf for `w` is filled.
///           π   = `siblings` — the sibling hashes along the leaf's path (length TREE_DEPTH).
///
///         The contract folds π twice along the key-derived path: once from the EMPTY leaf
///         (must equal the current root `signalRoot[s]`, proving the leaf is empty — i.e.
///         `w` is NOT already registered — and π is the genuine cofactor) and once from the
///         filled leaf (must equal `r'`). Both are bound by Merkle collision resistance, so
///         a valid (r', π) is the unique honest insert and re-registering the same witness
///         fails the empty-leaf check. The key (witness) is read on-chain from the verifier,
///         never taken from the caller.
///
///         === Account uniqueness ===
///         The registry reads each verifier for `msg.sender` only, so a registration
///         aggregates witnesses that all belong to the same account. Because the dedup key
///         is the underlying witness (not the wallet), the same external account cannot be
///         registered from two different wallets.
contract DIDRegistry is SoulboundToken {
    // -----------------------------------------------------------------
    // Signals (each a witness-exposing verifier) & mechanism
    // -----------------------------------------------------------------

    struct SignalSource {
        address verifier;       // exposes identityWitness(address) (or a custom selector)
        bytes4 witnessSelector; // selector returning bytes32 witness for an account
    }

    /// @dev Mechanism terms are uint8 bitmaps, so at most 8 signals are supported.
    uint8 public constant MAX_SIGNALS = 8;

    SignalSource[] public signals;   // length == numSignals
    bytes32[] public signalRoot;     // per-signal Sparse Merkle Tree root
    uint8[] public terms;            // DNF: eligibility == OR of these AND-term bitmaps

    address public owner;

    // -----------------------------------------------------------------
    // Sparse Merkle Tree machinery (shared depth across signals)
    // -----------------------------------------------------------------

    bytes32 public constant DOMAIN = keccak256("DIDRegistry.v2");
    uint256 public immutable TREE_DEPTH;

    /// @dev Precomputed empty-subtree roots: zeros[i] = root of an empty subtree of
    ///      height i (zeros[0] is the empty-leaf value, 0). Clients building π need these.
    bytes32[] internal _zeros;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event Registered(address indexed account, uint8 indexed termIndex, uint8 termMask, uint256 tokenId);
    event SignalInserted(uint8 indexed signal, bytes32 indexed key, bytes32 newRoot);
    event SignalSourceSet(uint8 indexed slot, address verifier, bytes4 witnessSelector);
    event MechanismSet(uint8[] terms);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    /// @param treeDepth         SMT depth for every signal; capacity is 2**treeDepth leaves.
    /// @param verifiers         Signal verifier addresses (length == n, 1..MAX_SIGNALS).
    /// @param witnessSelectors  Per-signal witness selector (e.g.
    ///                          bytes4(keccak256("identityWitness(address)"))).
    /// @param initialTerms      DNF term bitmaps. Each must be non-zero and reference only
    ///                          configured signals. Pass a single (2**n - 1) term for all-AND.
    constructor(
        uint256 treeDepth,
        address[] memory verifiers,
        bytes4[] memory witnessSelectors,
        uint8[] memory initialTerms
    ) SoulboundToken("Decentralised Identity Credential", "DID") {
        require(treeDepth >= 1 && treeDepth <= 160, "bad tree depth");
        uint256 n = verifiers.length;
        require(n >= 1 && n <= MAX_SIGNALS, "bad signal count");
        require(witnessSelectors.length == n, "selector length");
        TREE_DEPTH = treeDepth;

        // Precompute zero-subtree roots and the empty-tree root.
        _zeros.push(bytes32(0)); // zeros[0] = empty leaf
        for (uint256 i = 0; i < treeDepth; i++) {
            _zeros.push(_hashPair(_zeros[i], _zeros[i]));
        }
        bytes32 emptyRoot = _zeros[treeDepth];

        for (uint256 s = 0; s < n; s++) {
            require(verifiers[s] != address(0), "zero verifier");
            signals.push(SignalSource(verifiers[s], witnessSelectors[s]));
            signalRoot.push(emptyRoot);
            emit SignalSourceSet(uint8(s), verifiers[s], witnessSelectors[s]);
        }

        _setMechanism(initialTerms, n);

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    /// @notice Replace the eligibility mechanism (DNF term bitmaps).
    function setMechanism(uint8[] calldata newTerms) external onlyOwner {
        _setMechanism(newTerms, signals.length);
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

    /// @notice Re-point a signal's verifier/selector. Does NOT reset that signal's tree.
    function setSignalSource(uint8 slot, address verifier, bytes4 witnessSelector) external onlyOwner {
        require(slot < signals.length, "bad slot");
        require(verifier != address(0), "zero verifier");
        signals[slot] = SignalSource(verifier, witnessSelector);
        emit SignalSourceSet(slot, verifier, witnessSelector);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // -----------------------------------------------------------------
    // Signal / witness reading
    // -----------------------------------------------------------------

    function numSignals() public view returns (uint256) {
        return signals.length;
    }

    function termCount() external view returns (uint256) {
        return terms.length;
    }

    /// @notice The unique witness for `account` under signal `slot`, or 0 if not held.
    ///         This is also the key inserted into the signal's tree at registration.
    function witnessOf(uint8 slot, address account) public view returns (bytes32) {
        if (slot >= signals.length) return bytes32(0);
        SignalSource memory src = signals[slot];
        (bool ok, bytes memory ret) =
            src.verifier.staticcall(abi.encodeWithSelector(src.witnessSelector, account));
        if (!ok || ret.length < 32) return bytes32(0);
        return abi.decode(ret, (bytes32));
    }

    /// @notice Whether `account` currently holds signal `slot` (witness != 0).
    function hasSignal(uint8 slot, address account) public view returns (bool) {
        return witnessOf(slot, account) != bytes32(0);
    }

    /// @notice The bitmap of signals `account` currently holds (bit i == signal i).
    function signalBitmapOf(address account) public view returns (uint8 bitmap) {
        uint256 n = signals.length;
        for (uint256 s = 0; s < n; s++) {
            if (hasSignal(uint8(s), account)) bitmap |= uint8(1) << uint8(s);
        }
    }

    /// @notice Whether `account` holds every signal in term `termIndex`.
    function satisfiesTerm(address account, uint256 termIndex) public view returns (bool) {
        if (termIndex >= terms.length) return false;
        uint8 mask = terms[termIndex];
        return (mask & ~signalBitmapOf(account)) == 0;
    }

    /// @notice Bitmap of term indices `account` currently satisfies (bit i == term i).
    ///         A non-zero result means the account can register at least one term.
    function eligibleTerms(address account) external view returns (uint256 bitmap) {
        uint8 held = signalBitmapOf(account);
        for (uint256 i = 0; i < terms.length; i++) {
            if ((terms[i] & ~held) == 0) bitmap |= (uint256(1) << i);
        }
    }

    // -----------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------

    /// @dev One Sparse-Merkle insertion proof: the post-insert root and the sibling path.
    struct Insert {
        bytes32 newRoot;
        bytes32[] siblings;
    }

    /// @notice Register by satisfying term `termIndex`. For every signal in that term
    ///         (ascending signal order), supply one `Insert` proof; the witness/key is read
    ///         on-chain from the verifier. Each witness is inserted into its signal's tree,
    ///         which rejects any witness already registered (per-signal de-duplication).
    /// @param termIndex Which DNF term (disjunct) the caller is satisfying.
    /// @param inserts   One proof per signal in the term, in ascending signal order.
    /// @return tokenId  The freshly minted soulbound credential id.
    function register(uint8 termIndex, Insert[] calldata inserts)
        external
        returns (uint256 tokenId)
    {
        require(termIndex < terms.length, "bad term");
        uint8 mask = terms[termIndex];

        uint256 n = signals.length;
        uint256 j = 0;
        for (uint256 s = 0; s < n; s++) {
            if ((mask & (uint8(1) << uint8(s))) == 0) continue;

            // The witness is authoritative (read on-chain); the caller cannot forge it.
            bytes32 key = witnessOf(uint8(s), msg.sender);
            require(key != bytes32(0), "signal not held");

            require(j < inserts.length, "missing insert");
            Insert calldata ins = inserts[j++];
            _smtInsert(uint8(s), key, ins.newRoot, ins.siblings);
            emit SignalInserted(uint8(s), key, ins.newRoot);
        }
        require(j == inserts.length, "extra inserts");

        tokenId = _mint(msg.sender);
        emit Registered(msg.sender, termIndex, mask, tokenId);
    }

    // -----------------------------------------------------------------
    // Sparse Merkle Tree internals
    // -----------------------------------------------------------------

    /// @notice The leaf value stored for a key (witness). Domain-tagged so it can never
    ///         collide with an internal node or the empty leaf.
    function leafHash(bytes32 key) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("DIDRegistry.smt-leaf", key));
    }

    /// @dev Verifies that filling the (currently empty) leaf for `key` in signal `s`'s
    ///      tree, using sibling path `siblings`, turns the current root into `newRoot`,
    ///      then commits it. Reverts if the leaf is already filled (witness duplicate).
    function _smtInsert(
        uint8 s,
        bytes32 key,
        bytes32 newRoot,
        bytes32[] calldata siblings
    ) internal {
        require(siblings.length == TREE_DEPTH, "bad proof length");
        bytes32 leaf = leafHash(key);

        // The leaf position is the low TREE_DEPTH bits of the key (consumed LSB-first).
        uint256 idx = uint256(key);
        bytes32 emptyNode = bytes32(0); // empty-leaf value
        bytes32 filledNode = leaf;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            bytes32 sib = siblings[i];
            if (idx & 1 == 0) {
                emptyNode = _hashPair(emptyNode, sib);
                filledNode = _hashPair(filledNode, sib);
            } else {
                emptyNode = _hashPair(sib, emptyNode);
                filledNode = _hashPair(sib, filledNode);
            }
            idx >>= 1;
        }
        // Folding the EMPTY leaf must reproduce the current root: proves the witness is
        // not yet registered AND that `siblings` is the genuine cofactor.
        require(emptyNode == signalRoot[s], "duplicate or stale proof");
        require(filledNode == newRoot, "newRoot mismatch");

        signalRoot[s] = newRoot;
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

    /// @notice Convenience: the leaf index (path) a witness key occupies in any tree.
    function leafIndexOf(bytes32 key) external view returns (uint256) {
        uint256 mask = TREE_DEPTH >= 256 ? type(uint256).max : (uint256(1) << TREE_DEPTH) - 1;
        return uint256(key) & mask;
    }
}
