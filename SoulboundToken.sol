// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SoulboundToken
/// @notice A minimal, non-transferable ("soulbound") token used by DIDRegistry to
///         issue one membership credential per registered proof. An address may hold
///         several credentials over time — one for each distinct proof it registers.
///
///         It exposes the read-only surface of ERC-721 (so wallets / explorers can
///         display it) and implements EIP-5192 (`locked()` + `Locked` event), but
///         every transfer / approval entry point reverts. There is no `_burn`; a
///         soulbound credential is permanent by design.
///
///         Token ids start at 1.
abstract contract SoulboundToken {
    string public name;
    string public symbol;

    uint256 public lastId; // also serves as totalSupply (ids are never burned)
    mapping(uint256 => address) internal _ownerOf;
    mapping(address => uint256) internal _balance;

    // ERC-721 events (kept so indexers/wallets recognise the mint).
    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    // EIP-5192: emitted at mint to mark the token permanently locked.
    event Locked(uint256 tokenId);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    // ---- ERC-721 (read-only parts) ----

    function balanceOf(address owner) public view returns (uint256) {
        require(owner != address(0), "zero address");
        return _balance[owner];
    }

    function ownerOf(uint256 id) public view returns (address owner) {
        owner = _ownerOf[id];
        require(owner != address(0), "no such token");
    }

    /// @notice EIP-5192: every credential is permanently locked.
    function locked(uint256 id) external view returns (bool) {
        ownerOf(id); // reverts if the token doesn't exist
        return true;
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    /// @notice Subclasses may override to return real metadata.
    function tokenURI(uint256 id) external view virtual returns (string memory) {
        ownerOf(id);
        return "";
    }

    // ERC-165: 0x01ffc9a7 (165), 0x80ac58cd (721), 0x5b5e139f (metadata), 0xb45a3c0e (5192).
    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return iid == 0x01ffc9a7 || iid == 0x80ac58cd || iid == 0x5b5e139f || iid == 0xb45a3c0e;
    }

    // ---- transfers / approvals: disabled ----

    function transferFrom(address, address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert("soulbound: non-transferable");
    }

    function approve(address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function setApprovalForAll(address, bool) external pure {
        revert("soulbound: non-transferable");
    }

    // ---- mint (internal) ----

    /// @dev Mints a fresh credential to `to`. An address may accumulate several.
    function _mint(address to) internal returns (uint256 id) {
        require(to != address(0), "mint to zero");
        id = ++lastId;
        _ownerOf[id] = to;
        _balance[to] += 1;
        emit Transfer(address(0), to, id);
        emit Locked(id);
    }
}
