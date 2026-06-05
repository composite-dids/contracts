// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReclaimIdentity.sol";

/// @title GoogleIdentity
/// @notice Proves the caller controls a Google account / email, via Reclaim zkTLS.
///         Records the verified email for msg.sender.
///
/// @dev fieldKey is the extracted-parameter the Google provider exposes. Reclaim's
///      Google/email providers typically emit "email"; if your chosen provider emits a
///      different key (check the dashboard provider config), deploy a variant with the
///      right key.
contract GoogleIdentity is ReclaimIdentity {
    /// @param reclaimAddr          Reclaim verifier (Sepolia: 0xAe94FB09711e1c6B057853a515483792d8e474d0)
    /// @param expectedProviderHash providerHash for your Google provider, or "" to skip binding.
    constructor(address reclaimAddr, string memory expectedProviderHash)
        ReclaimIdentity(reclaimAddr, expectedProviderHash, '"email":"', "google")
    {}
}
