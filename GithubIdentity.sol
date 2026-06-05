// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReclaimIdentity.sol";

/// @title GithubIdentity
/// @notice Proves the caller controls a GitHub account, via Reclaim zkTLS.
///         Records the verified GitHub username for msg.sender.
///
/// @dev fieldKey is the extracted-parameter the GitHub provider exposes. Reclaim's
///      GitHub username provider uses "username"; if your chosen provider emits a
///      different key (check the dashboard provider config), deploy a variant with the
///      right key.
contract GithubIdentity is ReclaimIdentity {
    /// @param reclaimAddr          Reclaim verifier (Sepolia: 0xAe94FB09711e1c6B057853a515483792d8e474d0)
    /// @param expectedProviderHash providerHash for your GitHub provider, or "" to skip binding.
    constructor(address reclaimAddr, string memory expectedProviderHash)
        ReclaimIdentity(reclaimAddr, expectedProviderHash, '"username":"', "github")
    {}
}
