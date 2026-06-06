// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReclaimIdentity.sol";

/// @title ArxivIdentity
/// @notice Proves the caller controls an arXiv account that has at least `minPapers`
///         papers, via Reclaim zkTLS. Records the captured paper identifier.
///
/// @dev Two layers enforce "≥ 1 paper":
///        1. The Reclaim provider must scrape your (login-gated) "articles owned" page
///           and only match when a paper is present — so a proof can't be generated for
///           an account with zero papers. It captures the first paper id into a field.
///        2. This contract requires that captured field (`fieldKey`) to be non-empty
///           (handled by the base), and — if `minPapers > 1` — additionally parses a
///           numeric `"paperCount":"` field from the context and requires it ≥ minPapers.
///
///      This contract reads the `first_paper_title` extracted parameter (the title of
///      the first paper on the login-gated page). For minPapers > 1 it also parses a
///      numeric `paperCount` parameter. Adjust the keys here if your provider differs.
contract ArxivIdentity is ReclaimIdentity {
    uint256 public immutable minPapers;
    string private constant COUNT_KEY = '"paperCount":"';

    /// @param reclaimAddr          Reclaim verifier (Sepolia: 0xAe94FB09711e1c6B057853a515483792d8e474d0)
    /// @param expectedProviderHash providerHash for your arXiv provider, or "" to skip binding.
    /// @param minPapers_           minimum papers. 0/1 → rely on the captured paper being
    ///                             present (≥ 1). >1 → also enforce the numeric paperCount.
    constructor(address reclaimAddr, string memory expectedProviderHash, uint256 minPapers_)
        ReclaimIdentity(reclaimAddr, expectedProviderHash, '"first_paper_title":"', "arxiv")
    {
        minPapers = minPapers_;
    }

    function _afterExtract(string memory context, string memory /*handle*/) internal view override {
        if (minPapers > 1) {
            require(_toUint(_extract(context, COUNT_KEY)) >= minPapers, "not enough papers");
        }
        // minPapers <= 1: the base already required a non-empty captured paper id => >= 1.
    }

    /// @dev Parse a decimal string to uint (reverts on empty or non-digit input).
    function _toUint(string memory s) internal pure returns (uint256 n) {
        bytes memory b = bytes(s);
        require(b.length > 0, "no count");
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            require(c >= 48 && c <= 57, "bad count");
            n = n * 10 + (c - 48);
        }
    }
}
