// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../DIDRegistry.sol";

/// Mimics BeaconIdentityVerifier's accessor: isVerified(address) -> bool.
contract MockBeacon {
    mapping(address => bool) public isVerified;
    function set(address a, bool v) external { isVerified[a] = v; }
}

/// Mimics HistoricalBalanceVerifier's accessor: isEligible(address) -> bool.
contract MockBalance {
    mapping(address => bool) public isEligible;
    function set(address a, bool v) external { isEligible[a] = v; }
}

/// Off-chain-equivalent incremental Merkle tree, used to build the (r', π) the
/// contract expects. Mirrors DIDRegistry's hashing exactly.
contract TreeMirror {
    uint256 public immutable depth;
    bytes32[] public zeros;
    bytes32[] public filled; // filledSubtrees per level
    uint256 public count;
    bytes32 public root;

    constructor(uint256 d) {
        depth = d;
        zeros.push(bytes32(0));
        filled.push(bytes32(0));
        for (uint256 i = 0; i < d; i++) {
            zeros.push(_h(zeros[i], zeros[i]));
            filled.push(bytes32(0));
        }
        for (uint256 i = 0; i < d; i++) filled[i] = zeros[i];
        root = zeros[d];
    }

    function _h(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    /// Returns the (newRoot, path) for appending `leaf` at the current frontier,
    /// without mutating state.
    function preview(bytes32 leaf) public view returns (bytes32 newRoot, bytes32[] memory path) {
        path = new bytes32[](depth);
        uint256 idx = count;
        bytes32 cur = leaf;
        for (uint256 i = 0; i < depth; i++) {
            if (idx & 1 == 0) {
                path[i] = zeros[i];
                cur = _h(cur, zeros[i]);
            } else {
                path[i] = filled[i];
                cur = _h(filled[i], cur);
            }
            idx >>= 1;
        }
        newRoot = cur;
    }

    /// Commit the append (updates frontier + root).
    function insert(bytes32 leaf) external {
        uint256 idx = count;
        bytes32 cur = leaf;
        for (uint256 i = 0; i < depth; i++) {
            if (idx & 1 == 0) {
                filled[i] = cur;
                cur = _h(cur, zeros[i]);
            } else {
                cur = _h(filled[i], cur);
            }
            idx >>= 1;
        }
        root = cur;
        count += 1;
    }
}

contract DIDRegistryTest is Test {
    DIDRegistry reg;
    MockBeacon beacon;
    MockBalance balance;
    TreeMirror mirror;

    uint256 constant DEPTH = 8;
    bytes4 constant SEL_VERIFIED = bytes4(keccak256("isVerified(address)"));
    bytes4 constant SEL_ELIGIBLE = bytes4(keccak256("isEligible(address)"));

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        beacon = new MockBeacon();
        balance = new MockBalance();
        address[4] memory v = [address(beacon), address(balance), address(0), address(0)];
        bytes4[4] memory s = [SEL_VERIFIED, SEL_ELIGIBLE, bytes4(0), bytes4(0)];
        reg = new DIDRegistry(DEPTH, v, s);
        mirror = new TreeMirror(DEPTH);
    }

    // Build register() args for `who`, matching the contract's current frontier.
    function _args(address who, uint8 bitmap)
        internal
        view
        returns (bytes32 newRoot, bytes32[] memory path)
    {
        bytes32 commitment = reg.previewCommitment(who, bitmap);
        (newRoot, path) = mirror.preview(commitment);
    }

    function test_InitialRootMatchesEmptyTree() public view {
        assertEq(reg.root(), mirror.root(), "empty roots differ");
        assertTrue(reg.isKnownRoot(reg.root()), "empty root must be known");
    }

    function test_RegisterWithOneSignal() public {
        beacon.set(alice, true); // signal 0 only -> bitmap = 1
        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 1);

        vm.prank(alice);
        (uint256 tokenId, uint256 idx) = reg.register(1, newRoot, path);
        mirror.insert(reg.previewCommitment(alice, 1));

        assertEq(idx, 0, "first leaf index");
        assertEq(tokenId, 1, "first token id");
        assertTrue(reg.isRegistered(alice), "alice registered");
        assertEq(reg.signalsOf(alice), 1, "recorded bitmap");
        assertEq(reg.root(), mirror.root(), "root after insert");
        assertTrue(reg.isKnownRoot(newRoot), "new root remembered");
        assertEq(reg.balanceOf(alice), 1, "holds one SBT");
        assertEq(reg.ownerOf(1), alice, "owner of token 1");
    }

    function test_RegisterAggregatesTwoSignals() public {
        beacon.set(alice, true);
        balance.set(alice, true); // bitmap = 0b11 = 3
        assertEq(reg.signalBitmapOf(alice), 3, "two signals aggregated");

        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 3);
        vm.prank(alice);
        reg.register(3, newRoot, path);
        assertEq(reg.signalsOf(alice), 3, "stored bitmap");
    }

    function test_NewProofMintsAnotherToken() public {
        // alice first registers with only the validator signal (bitmap = 1).
        beacon.set(alice, true);
        (bytes32 nr1, bytes32[] memory p1) = _args(alice, 1);
        vm.prank(alice);
        (uint256 t1,) = reg.register(1, nr1, p1);
        mirror.insert(reg.previewCommitment(alice, 1));

        // Later she also proves balance -> her signal-set is now bitmap = 3, a NEW proof.
        balance.set(alice, true);
        assertEq(reg.signalBitmapOf(alice), 3, "now holds both signals");
        (bytes32 nr2, bytes32[] memory p2) = _args(alice, 3);
        vm.prank(alice);
        (uint256 t2, uint256 idx2) = reg.register(3, nr2, p2);
        mirror.insert(reg.previewCommitment(alice, 3));

        assertEq(t1, 1, "first credential id");
        assertEq(t2, 2, "second, distinct credential id");
        assertEq(idx2, 1, "second proof is the second leaf");
        assertEq(reg.balanceOf(alice), 2, "alice now holds two credentials");
        assertEq(reg.ownerOf(2), alice, "owns the new credential");
        assertEq(reg.signalsOf(alice), 3, "accumulated signal union");
        assertEq(reg.root(), mirror.root(), "root after two appends");

        // The exact same upgraded proof can't be registered again.
        (bytes32 nr3, bytes32[] memory p3) = _args(alice, 3);
        vm.prank(alice);
        vm.expectRevert(bytes("already registered"));
        reg.register(3, nr3, p3);
    }

    function test_DuplicateProofRejected() public {
        beacon.set(alice, true);
        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 1);
        vm.prank(alice);
        reg.register(1, newRoot, path);
        mirror.insert(reg.previewCommitment(alice, 1));

        // Exactly the same proof again -> rejected by the de-dup set.
        (bytes32 nr2, bytes32[] memory p2) = _args(alice, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("already registered"));
        reg.register(1, nr2, p2);
    }

    function test_TwoUsersRegisterSequentially() public {
        beacon.set(alice, true);
        balance.set(bob, true);

        (bytes32 nrA, bytes32[] memory pA) = _args(alice, 1);
        vm.prank(alice);
        reg.register(1, nrA, pA);
        mirror.insert(reg.previewCommitment(alice, 1));

        (bytes32 nrB, bytes32[] memory pB) = _args(bob, 2);
        vm.prank(bob);
        (, uint256 idxB) = reg.register(2, nrB, pB);
        mirror.insert(reg.previewCommitment(bob, 2));

        assertEq(idxB, 1, "bob is second leaf");
        assertEq(reg.root(), mirror.root(), "root after two inserts");
        assertEq(reg.ownerOf(2), bob, "bob holds token 2");
    }

    function test_NoSignalReverts() public {
        // alice has no signals set.
        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("signal mismatch"));
        reg.register(1, newRoot, path);
    }

    function test_ClaimedBitmapMustMatch() public {
        beacon.set(alice, true); // real bitmap = 1
        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 3); // claim 3
        vm.prank(alice);
        vm.expectRevert(bytes("signal mismatch"));
        reg.register(3, newRoot, path);
    }

    function test_StaleRootRejected() public {
        beacon.set(alice, true);
        balance.set(bob, true);
        // Build alice's args, but let bob register first so the frontier moves.
        (bytes32 nrA, bytes32[] memory pA) = _args(alice, 1);

        (bytes32 nrB, bytes32[] memory pB) = _args(bob, 2);
        vm.prank(bob);
        reg.register(2, nrB, pB);

        // alice's path was for index 0, now stale -> reverts.
        vm.prank(alice);
        vm.expectRevert();
        reg.register(1, nrA, pA);
    }

    function test_BadNewRootRejected() public {
        beacon.set(alice, true);
        (, bytes32[] memory path) = _args(alice, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("newRoot mismatch"));
        reg.register(1, bytes32(uint256(123)), path);
    }

    function test_SoulboundTransfersRevert() public {
        beacon.set(alice, true);
        (bytes32 newRoot, bytes32[] memory path) = _args(alice, 1);
        vm.prank(alice);
        reg.register(1, newRoot, path);

        vm.prank(alice);
        vm.expectRevert(bytes("soulbound: non-transferable"));
        reg.transferFrom(alice, bob, 1);

        assertTrue(reg.locked(1), "token is locked");
    }

    function test_RegisterAllFourSignals() public {
        // Wire all four slots: beacon(isVerified), balance(isEligible),
        // github(isVerified), google(isVerified) — the full integrated set.
        MockBeacon github = new MockBeacon();
        MockBeacon google = new MockBeacon();
        address[4] memory v = [address(beacon), address(balance), address(github), address(google)];
        bytes4[4] memory s = [SEL_VERIFIED, SEL_ELIGIBLE, SEL_VERIFIED, SEL_VERIFIED];
        DIDRegistry r = new DIDRegistry(DEPTH, v, s);
        TreeMirror m = new TreeMirror(DEPTH);

        // alice proves every signal.
        beacon.set(alice, true);
        balance.set(alice, true);
        github.set(alice, true);
        google.set(alice, true);
        assertEq(r.signalBitmapOf(alice), 15, "all four signals -> bitmap 1111");

        bytes32 commitment = r.previewCommitment(alice, 15);
        (bytes32 newRoot, bytes32[] memory path) = m.preview(commitment);
        vm.prank(alice);
        (uint256 tokenId, uint256 idx) = r.register(15, newRoot, path);

        assertEq(idx, 0, "first leaf");
        assertEq(tokenId, 1, "credential minted");
        assertEq(r.signalsOf(alice), 15, "all signals recorded");
        assertTrue(r.isRegistered(alice), "registered with the full signal set");
        m.insert(commitment);
        assertEq(r.root(), m.root(), "root matches after the 4-signal append");
    }

    function test_OwnerCanWireThirdSignal() public {
        MockBeacon third = new MockBeacon();
        reg.setSignalSource(2, address(third), SEL_VERIFIED);
        third.set(alice, true); // now slot 2 -> bit 2 = 4
        assertEq(reg.signalBitmapOf(alice), 4, "third signal counts");
    }

    function test_NonOwnerCannotWireSignal() public {
        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        reg.setSignalSource(2, address(beacon), SEL_VERIFIED);
    }

    function test_ReservedSlotsAreEmptyByDefault() public view {
        (address v2,) = reg.signals(2);
        (address v3,) = reg.signals(3);
        assertEq(v2, address(0), "slot 2 reserved/empty");
        assertEq(v3, address(0), "slot 3 reserved/empty");
        assertFalse(reg.hasSignal(2, alice), "empty slot -> no signal");
    }
}
