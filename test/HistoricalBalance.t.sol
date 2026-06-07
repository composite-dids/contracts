// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../HistoricalBalanceVerifier.sol";

/// Exposes the verifier's internals for isolated, fork-free unit testing.
contract ExposedVerifier is HistoricalBalanceVerifier {
    constructor(uint256 minAge, uint256 minBal) HistoricalBalanceVerifier(minAge, minBal) {}

    function xParseHeader(bytes calldata h) external pure returns (bytes32 sr, uint256 n) {
        return _parseHeader(h);
    }

    function xBalance(bytes calldata a) external pure returns (uint256) {
        return _accountBalance(a);
    }

    function xBlockHash(uint256 n) external view returns (bytes32) {
        return _historicalBlockHash(n);
    }
}

/// Tests run against a real mainnet block + eth_getProof fixture
/// (test/fixtures/balance_mainnet.json, regenerate with gen_fixture.py).
contract HistoricalBalanceTest is Test {
    string json;
    address addr;
    uint256 targetBlock;
    uint256 forkBlock;
    bytes32 blockHash;
    bytes32 stateRoot;
    bytes headerRLP;
    bytes[] accountProof;
    uint256 balanceWei;
    string rpc;
    uint256 deepBlock;
    bytes32 deepBlockHash;

    function setUp() public {
        json = vm.readFile("test/fixtures/balance_mainnet.json");
        addr = vm.parseJsonAddress(json, ".address");
        targetBlock = vm.parseJsonUint(json, ".targetBlock");
        forkBlock = vm.parseJsonUint(json, ".forkBlock");
        blockHash = vm.parseJsonBytes32(json, ".blockHash");
        stateRoot = vm.parseJsonBytes32(json, ".stateRoot");
        headerRLP = vm.parseJsonBytes(json, ".headerRLP");
        accountProof = vm.parseJsonBytesArray(json, ".accountProof");
        balanceWei = vm.parseUint(vm.parseJsonString(json, ".balanceWei"));
        rpc = vm.parseJsonString(json, ".rpc");
        deepBlock = vm.parseJsonUint(json, ".deepBlock");
        deepBlockHash = vm.parseJsonBytes32(json, ".deepBlockHash");
    }

    // ---- offline cryptography (no network) ----

    function test_HeaderRlpHashesToBlockHash() public view {
        assertEq(keccak256(headerRLP), blockHash, "header rlp != block hash");
    }

    function test_ParseHeader() public {
        ExposedVerifier v = new ExposedVerifier(1, 0);
        (bytes32 sr, uint256 n) = v.xParseHeader(headerRLP);
        assertEq(sr, stateRoot, "stateRoot");
        assertEq(n, targetBlock, "block number");
    }

    function test_MptProvesBalance() public {
        bytes32 key = keccak256(abi.encodePacked(addr));
        (bool ok, bytes memory acct) =
            MerklePatricia.verifyInclusion(stateRoot, abi.encodePacked(key), accountProof);
        assertTrue(ok, "mpt inclusion failed");

        ExposedVerifier v = new ExposedVerifier(1, 0);
        assertEq(v.xBalance(acct), balanceWei, "decoded balance");
    }

    function test_MptRejectsWrongStateRoot() public view {
        bytes32 key = keccak256(abi.encodePacked(addr));
        (bool ok,) = MerklePatricia.verifyInclusion(
            bytes32(uint256(stateRoot) ^ 1), abi.encodePacked(key), accountProof
        );
        assertFalse(ok, "must reject a bad root");
    }

    function test_MptRejectsWrongAddress() public view {
        bytes32 key = keccak256(abi.encodePacked(address(0xDEAD)));
        (bool ok,) =
            MerklePatricia.verifyInclusion(stateRoot, abi.encodePacked(key), accountProof);
        assertFalse(ok, "proof is for a different address");
    }

    // ---- full path against a forked chain (uses the public RPC) ----

    function testFork_VerifyBalanceAt() public {
        vm.createSelectFork(rpc, forkBlock);
        // MIN_AGE=1: the public node prunes deep state, so the fixture is anchored a
        // few blocks back. The blockhash/window logic is identical at any age.
        ExposedVerifier v = new ExposedVerifier(1, 0.1 ether);
        uint256 bal = v.verifyBalanceAt(targetBlock, headerRLP, addr, accountProof);
        assertEq(bal, balanceWei, "end-to-end verified balance");
    }

    function testFork_VerifyAndGetWitness() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1, 0.1 ether);
        bytes memory proofData = abi.encode(targetBlock, headerRLP, accountProof);
        string memory handle = v.verifyAndGetWitness(addr, proofData);
        assertEq(bytes(handle).length, 42, "handle is a 0x-address string");
        assertEq(bytes(handle)[0], bytes1("0"));
        assertEq(bytes(handle)[1], bytes1("x"));
    }

    function testFork_ProveSelfBalance() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1, 0.1 ether);
        // The proof is for `addr`, so the caller must be `addr`.
        vm.prank(addr);
        v.proveSelfBalance(targetBlock, headerRLP, accountProof);
        assertTrue(v.isEligible(addr), "caller marked eligible");
        assertGe(balanceWei, 0.1 ether, "fixture should clear the threshold");
    }

    function testFork_RevertsWhenBelowMinimum() public {
        vm.createSelectFork(rpc, forkBlock);
        // Threshold absurdly high so the real balance can't meet it.
        ExposedVerifier v = new ExposedVerifier(1, 1_000_000 ether);
        vm.prank(addr);
        vm.expectRevert(bytes("balance below minimum"));
        v.proveSelfBalance(targetBlock, headerRLP, accountProof);
        assertFalse(v.isEligible(addr), "must not be eligible");
    }

    function testFork_RevertsOnWrongCaller() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1, 0.1 ether);
        // Caller is not the proven address -> msg.sender proof can't match -> revert.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        v.proveSelfBalance(targetBlock, headerRLP, accountProof);
    }

    function testFork_BlockHashSources() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1, 0);
        // Recent block (< 256 back): served by the BLOCKHASH opcode.
        assertEq(v.xBlockHash(targetBlock), blockHash, "opcode path");
        // Deep block (> 256 back): served by the EIP-2935 history contract.
        assertGt(forkBlock - deepBlock, 256, "deep block must be beyond BLOCKHASH");
        assertEq(v.xBlockHash(deepBlock), deepBlockHash, "EIP-2935 path");
    }

    function testFork_RevertsOnTamperedHeader() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1, 0.1 ether);
        bytes memory bad = headerRLP;
        bad[100] ^= 0x01; // flip a byte -> keccak != blockhash
        vm.expectRevert();
        v.verifyBalanceAt(targetBlock, bad, addr, accountProof);
    }
}
