// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CostEstimateScript} from "./CostEstimate.s.sol";

/// @notice Interactive overlay on `CostEstimateScript`: prompts for a real
/// population (citizens, candidates, vendors, donation rate) and, when not
/// forked, the L1 price level too, instead of using SPEC Section 8's fixed
/// illustrative example / reading `L1_SCENARIO` from the environment. Reuses
/// the exact same deployment/measurement/report-building machinery -- same
/// methodology, parameters, per-action table and Section 8 breakdown, just with
/// user-chosen values dropped in via five small overrides (`_population()`/
/// `_populationIsIllustrative()`/`_reportBasename()`/`_l1ScenarioLabel()`/
/// `_scenarioSourceLabel()`). `run()` itself is inherited unchanged.
///
/// The price-level prompt is skipped when forked -- Base's live basefee is used
/// instead either way, same as `CostEstimateScript` (see `_onBaseFork`). Same
/// one-scenario-per-run model, for the same reason (create/claim/donate gas is
/// `block.basefee`-sensitive). Needs an interactive terminal (`vm.promptUint`/
/// `vm.prompt`) -- doesn't work piped or in CI. Run:
///   forge test --mt test_B3                                                          # prerequisite
///   forge script script/InteractiveCostEstimate.s.sol                                # prompts for L1 level too
///   forge script script/InteractiveCostEstimate.s.sol --fork-url https://mainnet.base.org  # Base, no price prompt
contract InteractiveCostEstimateScript is CostEstimateScript {
    // Same simplifying assumption as CostEstimateScript's default population:
    // each candidate/vendor sweeps its accumulated vouchers in exactly one
    // batched transaction. Not prompted for -- the four population inputs below
    // are the ones that actually vary run to run.
    uint256 internal constant SPEND_TXS_PER_CANDIDATE = 1;
    uint256 internal constant REDEEM_TXS_PER_VENDOR = 1;

    function _population() internal override returns (Population memory) {
        uint256 nCit = vm.promptUint("Number of citizens");
        uint256 nCand = vm.promptUint("Number of candidates");
        uint256 nVen = vm.promptUint("Number of vendors");
        uint256 donationPercent = vm.promptUint("Donation rate, percent of citizens who donate a voucher (0-100)");
        require(donationPercent <= 100, "donation rate must be between 0 and 100");

        return Population({
            nCit: nCit,
            nCand: nCand,
            nVen: nVen,
            donationPercent: donationPercent,
            spendTxsPerCandidate: SPEND_TXS_PER_CANDIDATE,
            redeemTxsPerVendor: REDEEM_TXS_PER_VENDOR
        });
    }

    function _populationIsIllustrative() internal pure override returns (bool) {
        return false;
    }

    function _reportBasename() internal pure override returns (string memory) {
        return "InteractiveCostEstimate";
    }

    function _l1ScenarioLabel() internal override returns (string memory) {
        return vm.prompt("L1 gas price level (low, normal, or high)");
    }

    function _scenarioSourceLabel() internal pure override returns (string memory) {
        return "interactive prompt";
    }
}
