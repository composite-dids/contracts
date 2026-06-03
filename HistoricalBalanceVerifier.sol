// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HistoricalBalanceVerifier
/// @notice Proves on-chain that `account` held a particular ETH balance at a block
///         ~100 blocks in the past — with no oracle and no trusted party.
///
/// @dev Chain of trust (all verified in this contract):
///        blockhash(targetBlock)                    -- EVM, last 256 blocks
///          == keccak256(headerRLP)                 -- ties the header to the chain
///          -> header.stateRoot (field 3)           -- RLP-decoded here
///          -> MPT account proof at keccak256(addr) -- verified against stateRoot
///          -> account = [nonce, balance, storageRoot, codeHash]
///          -> balance (field 1)
///
///      Window: BLOCKHASH only reaches back 256 blocks (~51 min). The target must be
///      between MIN_AGE and 256 blocks old. The proof service anchors at head-100, so
///      there is a ~156-block (~31 min) margin to land the transaction.
///
///      To reach further back (up to 8191 blocks) on post-Pectra chains, swap the
///      BLOCKHASH lookup for the EIP-2935 history contract — see _historicalBlockHash.
contract HistoricalBalanceVerifier {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    uint256 public constant MAX_AGE = 256; // BLOCKHASH reach
    uint256 public immutable MIN_AGE;       // how old the target block must be (default 100)

    // account => blockNumber => proven balance (wei). Guard reads with isProven.
    mapping(address => mapping(uint256 => uint256)) public provenBalanceWei;
    mapping(address => mapping(uint256 => bool)) public isProven;

    event BalanceProven(address indexed account, uint256 indexed blockNumber, uint256 balanceWei);

    /// @param minAge minimum age (in blocks) the target must have. 100 per the spec.
    constructor(uint256 minAge) {
        require(minAge >= 1 && minAge <= MAX_AGE, "bad minAge");
        MIN_AGE = minAge;
    }

    // ---------------------------------------------------------------------
    // View: verify and return the balance without storing anything.
    // ---------------------------------------------------------------------
    function verifyBalanceAt(
        uint256 targetBlock,
        bytes calldata headerRLP,
        address account,
        bytes[] calldata accountProof
    ) public view returns (uint256 balanceWei) {
        require(targetBlock < block.number, "target not in past");
        uint256 age = block.number - targetBlock;
        require(age >= MIN_AGE && age <= MAX_AGE, "outside block window");

        bytes32 bh = blockhash(targetBlock);
        require(bh != bytes32(0), "blockhash unavailable");
        require(keccak256(headerRLP) == bh, "header != blockhash");

        (bytes32 stateRoot, uint256 number) = _parseHeader(headerRLP);
        require(number == targetBlock, "header number mismatch");

        bytes32 key = keccak256(abi.encodePacked(account));
        (bool ok, bytes memory accountRLP) =
            MerklePatricia.verifyInclusion(stateRoot, abi.encodePacked(key), accountProof);
        require(ok, "account proof failed");

        balanceWei = _accountBalance(accountRLP);
    }

    // ---------------------------------------------------------------------
    // Stateful: verify and record an attestation (permissionless — the proof
    // is self-validating, so anyone may submit it for any address).
    // ---------------------------------------------------------------------
    function attest(
        uint256 targetBlock,
        bytes calldata headerRLP,
        address account,
        bytes[] calldata accountProof
    ) external returns (uint256 balanceWei) {
        balanceWei = verifyBalanceAt(targetBlock, headerRLP, account, accountProof);
        provenBalanceWei[account][targetBlock] = balanceWei;
        isProven[account][targetBlock] = true;
        emit BalanceProven(account, targetBlock, balanceWei);
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------
    function _parseHeader(bytes calldata headerRLP)
        internal
        pure
        returns (bytes32 stateRoot, uint256 number)
    {
        RLPReader.RLPItem[] memory fields = headerRLP.toRlpItem().toList();
        require(fields.length >= 9, "bad header");
        stateRoot = bytes32(fields[3].toUint()); // stateRoot is header field 3
        number = fields[8].toUint();             // number is header field 8
    }

    function _accountBalance(bytes memory accountRLP) internal pure returns (uint256) {
        RLPReader.RLPItem[] memory acct = accountRLP.toRlpItem().toList();
        require(acct.length == 4, "bad account");
        return acct[1].toUint(); // [nonce, balance, storageRoot, codeHash]
    }
}

// =====================================================================
// Merkle-Patricia inclusion proof (account trie)
// =====================================================================
library MerklePatricia {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    /// @param root   stateRoot to verify against.
    /// @param key32  the trie key (keccak256(address)), 32 bytes.
    /// @param proof  array of RLP-encoded trie nodes, root-first.
    /// @return ok    true if `key32` is included.
    /// @return value the RLP-encoded value stored at the leaf (the account).
    function verifyInclusion(bytes32 root, bytes memory key32, bytes[] memory proof)
        internal
        pure
        returns (bool ok, bytes memory value)
    {
        bytes memory nibbles = _toNibbles(key32); // 64 nibbles
        uint256 keyIndex = 0;
        bytes32 expected = root;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes memory node = proof[i];
            // Top-level account-trie nodes are always >= 32 bytes, so each is
            // referenced by hash; verify it links to the expected hash.
            if (keccak256(node) != expected) return (false, "");

            RLPReader.RLPItem[] memory items = node.toRlpItem().toList();

            if (items.length == 17) {
                // branch node
                if (keyIndex >= nibbles.length) {
                    return (true, items[16].toBytes()); // value sits in slot 16
                }
                uint8 nib = uint8(nibbles[keyIndex]);
                expected = bytes32(items[nib].toUint());
                keyIndex += 1;
            } else if (items.length == 2) {
                // leaf or extension
                (bool isLeaf, bytes memory pathNibbles) = _decodePath(items[0].toBytes());
                for (uint256 j = 0; j < pathNibbles.length; j++) {
                    if (keyIndex + j >= nibbles.length) return (false, "");
                    if (nibbles[keyIndex + j] != pathNibbles[j]) return (false, "");
                }
                keyIndex += pathNibbles.length;

                if (isLeaf) {
                    if (keyIndex != nibbles.length) return (false, "");
                    return (true, items[1].toBytes());
                } else {
                    expected = bytes32(items[1].toUint()); // extension -> next node
                }
            } else {
                return (false, "");
            }
        }
        return (false, "");
    }

    function _toNibbles(bytes memory b) private pure returns (bytes memory nibbles) {
        nibbles = new bytes(b.length * 2);
        for (uint256 i = 0; i < b.length; i++) {
            nibbles[2 * i] = bytes1(uint8(b[i]) >> 4);
            nibbles[2 * i + 1] = bytes1(uint8(b[i]) & 0x0f);
        }
    }

    /// @dev Decode a hex-prefix (compact) encoded path.
    ///      First nibble flag: 0/1 = extension, 2/3 = leaf; odd flag => odd length.
    function _decodePath(bytes memory path) private pure returns (bool isLeaf, bytes memory nibbles) {
        require(path.length > 0, "empty path");
        uint8 flag = uint8(path[0]) >> 4;
        isLeaf = flag >= 2;
        bool odd = (flag & 1) == 1;

        uint256 start = odd ? 1 : 2; // nibble index where the real path begins
        uint256 count = path.length * 2 - start;
        nibbles = new bytes(count);
        for (uint256 k = 0; k < count; k++) {
            uint256 idx = start + k;
            uint8 b = uint8(path[idx / 2]);
            nibbles[k] = (idx % 2 == 0) ? bytes1(b >> 4) : bytes1(b & 0x0f);
        }
    }
}

// =====================================================================
// Minimal RLP reader (Hamdi Allam style)
// =====================================================================
library RLPReader {
    uint8 constant STRING_SHORT_START = 0x80;
    uint8 constant STRING_LONG_START = 0xb8;
    uint8 constant LIST_SHORT_START = 0xc0;
    uint8 constant LIST_LONG_START = 0xf8;

    struct RLPItem {
        uint256 len;
        uint256 memPtr;
    }

    function toRlpItem(bytes memory item) internal pure returns (RLPItem memory) {
        uint256 memPtr;
        assembly {
            memPtr := add(item, 0x20)
        }
        return RLPItem(item.length, memPtr);
    }

    function isList(RLPItem memory item) internal pure returns (bool) {
        if (item.len == 0) return false;
        uint8 byte0;
        uint256 memPtr = item.memPtr;
        assembly {
            byte0 := byte(0, mload(memPtr))
        }
        return byte0 >= LIST_SHORT_START;
    }

    function toList(RLPItem memory item) internal pure returns (RLPItem[] memory result) {
        require(isList(item), "not a list");
        uint256 count = _numItems(item);
        result = new RLPItem[](count);
        uint256 memPtr = item.memPtr + _payloadOffset(item.memPtr);
        for (uint256 i = 0; i < count; i++) {
            uint256 dataLen = _itemLength(memPtr);
            result[i] = RLPItem(dataLen, memPtr);
            memPtr += dataLen;
        }
    }

    function toBytes(RLPItem memory item) internal pure returns (bytes memory result) {
        uint256 offset = _payloadOffset(item.memPtr);
        uint256 len = item.len - offset;
        result = new bytes(len);
        uint256 destPtr;
        assembly {
            destPtr := add(result, 0x20)
        }
        _copy(item.memPtr + offset, destPtr, len);
    }

    function toUint(RLPItem memory item) internal pure returns (uint256 result) {
        uint256 offset = _payloadOffset(item.memPtr);
        uint256 len = item.len - offset;
        require(len <= 32, "uint too long");
        uint256 memPtr = item.memPtr + offset;
        assembly {
            result := mload(memPtr)
        }
        // value occupies the high `len` bytes of the loaded word; right-align it.
        if (len < 32) {
            result = result >> (8 * (32 - len));
        }
    }

    function _numItems(RLPItem memory item) private pure returns (uint256 count) {
        uint256 currPtr = item.memPtr + _payloadOffset(item.memPtr);
        uint256 endPtr = item.memPtr + item.len;
        while (currPtr < endPtr) {
            currPtr += _itemLength(currPtr);
            count++;
        }
    }

    function _itemLength(uint256 memPtr) private pure returns (uint256 itemLen) {
        uint256 byte0;
        assembly {
            byte0 := byte(0, mload(memPtr))
        }
        if (byte0 < STRING_SHORT_START) {
            itemLen = 1;
        } else if (byte0 < STRING_LONG_START) {
            itemLen = byte0 - STRING_SHORT_START + 1;
        } else if (byte0 < LIST_SHORT_START) {
            uint256 lenOfLen = byte0 - (STRING_LONG_START - 1);
            uint256 dataLen;
            assembly {
                let p := add(memPtr, 1)
                dataLen := div(mload(p), exp(256, sub(32, lenOfLen)))
            }
            itemLen = dataLen + lenOfLen + 1;
        } else if (byte0 < LIST_LONG_START) {
            itemLen = byte0 - LIST_SHORT_START + 1;
        } else {
            uint256 lenOfLen = byte0 - (LIST_LONG_START - 1);
            uint256 dataLen;
            assembly {
                let p := add(memPtr, 1)
                dataLen := div(mload(p), exp(256, sub(32, lenOfLen)))
            }
            itemLen = dataLen + lenOfLen + 1;
        }
    }

    function _payloadOffset(uint256 memPtr) private pure returns (uint256) {
        uint256 byte0;
        assembly {
            byte0 := byte(0, mload(memPtr))
        }
        if (byte0 < STRING_SHORT_START) return 0;
        else if (byte0 < STRING_LONG_START) return 1;
        else if (byte0 < LIST_SHORT_START) return byte0 - (STRING_LONG_START - 1) + 1;
        else if (byte0 < LIST_LONG_START) return 1;
        else return byte0 - (LIST_LONG_START - 1) + 1;
    }

    function _copy(uint256 src, uint256 dest, uint256 len) private pure {
        for (; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            src += 32;
            dest += 32;
        }
        if (len > 0) {
            uint256 mask = 256 ** (32 - len) - 1;
            assembly {
                let srcpart := and(mload(src), not(mask))
                let destpart := and(mload(dest), mask)
                mstore(dest, or(destpart, srcpart))
            }
        }
    }
}
