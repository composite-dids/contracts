// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../HistoricalBalanceVerifier.sol";

/// Exposes the verifier's internals for isolated, fork-free unit testing.
contract ExposedVerifier is HistoricalBalanceVerifier {
    constructor(uint256 m) HistoricalBalanceVerifier(m) {}

    function xParseHeader(bytes calldata h) external pure returns (bytes32 sr, uint256 n) {
        return _parseHeader(h);
    }

    function xBalance(bytes calldata a) external pure returns (uint256) {
        return _accountBalance(a);
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
    }

    // ---- offline cryptography (no network) ----

    function test_HeaderRlpHashesToBlockHash() public view {
        assertEq(keccak256(headerRLP), blockHash, "header rlp != block hash");
    }

    function test_ParseHeader() public {
        ExposedVerifier v = new ExposedVerifier(1);
        (bytes32 sr, uint256 n) = v.xParseHeader(headerRLP);
        assertEq(sr, stateRoot, "stateRoot");
        assertEq(n, targetBlock, "block number");
    }

    function test_MptProvesBalance() public {
        bytes32 key = keccak256(abi.encodePacked(addr));
        (bool ok, bytes memory acct) =
            MerklePatricia.verifyInclusion(stateRoot, abi.encodePacked(key), accountProof);
        assertTrue(ok, "mpt inclusion failed");

        ExposedVerifier v = new ExposedVerifier(1);
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
        ExposedVerifier v = new ExposedVerifier(1);
        uint256 bal = v.verifyBalanceAt(targetBlock, headerRLP, addr, accountProof);
        assertEq(bal, balanceWei, "end-to-end verified balance");
    }

    function testFork_RecordsAttestation() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1);
        v.attest(targetBlock, headerRLP, addr, accountProof);
        assertTrue(v.isProven(addr, targetBlock), "isProven");
        assertEq(v.provenBalanceWei(addr, targetBlock), balanceWei, "stored balance");
    }

    function testFork_RevertsOnTamperedHeader() public {
        vm.createSelectFork(rpc, forkBlock);
        ExposedVerifier v = new ExposedVerifier(1);
        bytes memory bad = headerRLP;
        bad[100] ^= 0x01; // flip a byte -> keccak != blockhash
        vm.expectRevert();
        v.verifyBalanceAt(targetBlock, bad, addr, accountProof);
    }
}
