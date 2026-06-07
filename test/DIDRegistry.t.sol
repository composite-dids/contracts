// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../DIDRegistry.sol";

/// A toggleable signal verifier with the ISignalVerifier interface.
/// `set(account, handle)` grants/changes the readable identity; setValid(false) makes
/// the "proof" invalid. proofData is ignored (the real verifiers parse it).
/// (demo-local.sh deploys this for the local click-through.)
contract MockSignal is ISignalVerifier {
    mapping(address => string) public handleFor;
    bool public valid = true;

    function set(address a, string calldata h) external { handleFor[a] = h; }
    function setValid(bool v) external { valid = v; }

    function verifyAndGetWitness(address claimant, bytes calldata)
        external
        view
        returns (string memory)
    {
        require(valid, "mock: invalid proof");
        string memory h = handleFor[claimant];
        require(bytes(h).length > 0, "mock: identity not held");
        return h;
    }
}

contract DIDRegistryTest is Test {
    DIDRegistry reg;
    MockSignal s0; // balance
    MockSignal s1; // github
    MockSignal s2; // google
    MockSignal s3; // arxiv

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        s0 = new MockSignal(); s1 = new MockSignal(); s2 = new MockSignal(); s3 = new MockSignal();
        address[] memory v = new address[](4);
        v[0] = address(s0); v[1] = address(s1); v[2] = address(s2); v[3] = address(s3);
        uint8[] memory terms = new uint8[](1);
        terms[0] = 0x0f; // single all-AND term over the four signals
        reg = new DIDRegistry(v, terms); // test contract is owner
    }

    function _grantAll(address who) internal {
        s0.set(who, who == alice ? "0xalice" : "0xbob"); // balance handle = address-ish
        s1.set(who, "sarisht");                          // shared github handle for dedup test
        s2.set(who, who == alice ? "a@x.com" : "b@x.com");
        s3.set(who, who == alice ? "Paper A" : "Paper B");
    }

    function _proofs(uint256 k) internal pure returns (bytes[] memory p) {
        p = new bytes[](k); // content ignored by MockSignal
    }

    function test_RegisterAllAnd() public {
        _grantAll(alice);
        vm.prank(alice);
        uint256 id = reg.register(0, _proofs(4));
        assertEq(id, 1, "first token id");
        assertTrue(reg.isRegistered(alice), "registered");
        assertEq(reg.registeredSignalsOf(alice), 0x0f, "recorded bitmap");
        assertEq(reg.registrantOf(1, keccak256(bytes("sarisht"))), alice, "github handle -> alice");
        assertEq(reg.handleOfKey(1, keccak256(bytes("sarisht"))), "sarisht", "readable handle stored");
    }

    function test_RevertWhenSignalMissing() public {
        s0.set(alice, "0xalice"); s1.set(alice, "sarisht"); s2.set(alice, "a@x.com"); // arXiv missing
        vm.prank(alice);
        vm.expectRevert(bytes("mock: identity not held"));
        reg.register(0, _proofs(4));
        assertFalse(reg.isRegistered(alice));
    }

    function test_RevertOnInvalidProof() public {
        _grantAll(alice);
        s2.setValid(false); // google proof now "invalid"
        vm.prank(alice);
        vm.expectRevert(bytes("mock: invalid proof"));
        reg.register(0, _proofs(4));
    }

    /// Core requirement: reusing any one identity (same handle) blocks registration —
    /// even from a different wallet, atomically (nothing else gets recorded).
    function test_DedupBlocksReuseAcrossWallets() public {
        _grantAll(alice);
        vm.prank(alice);
        reg.register(0, _proofs(4));

        _grantAll(bob); // bob shares the same github handle "sarisht"
        vm.prank(bob);
        vm.expectRevert(bytes("signal identity already used"));
        reg.register(0, _proofs(4));

        assertFalse(reg.isRegistered(bob), "bob blocked by reused github identity");
        assertEq(reg.registrantOf(0, keccak256(bytes("0xbob"))), address(0), "no partial state");
    }

    function test_DNF_OrTerms() public {
        uint8[] memory t = new uint8[](2);
        t[0] = 0x03; // s0 AND s1
        t[1] = 0x0c; // s2 AND s3
        reg.setMechanism(t);

        s2.set(alice, "a@x.com"); s3.set(alice, "Paper A"); // only term 1
        vm.prank(alice);
        reg.register(1, _proofs(2));
        assertTrue(reg.isRegistered(alice));

        vm.prank(alice);
        vm.expectRevert(bytes("mock: identity not held")); // lacks s0,s1 for term 0
        reg.register(0, _proofs(2));
    }

    function test_RevertOnWrongProofCount() public {
        _grantAll(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("missing proof"));
        reg.register(0, _proofs(3)); // term 0 needs 4
    }

    function test_SoulboundNonTransferable() public {
        _grantAll(alice);
        vm.prank(alice);
        uint256 id = reg.register(0, _proofs(4));
        assertTrue(reg.locked(id));
        vm.prank(alice);
        vm.expectRevert(bytes("soulbound: non-transferable"));
        reg.transferFrom(alice, bob, id);
    }
}
