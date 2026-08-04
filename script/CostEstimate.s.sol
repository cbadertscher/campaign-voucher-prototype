// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/Script.sol";
import {CostMeasurement} from "./lib/CostMeasurement.sol";

/// @notice M5 (SPEC Sections 7/8): converts real measured gas into a USD cost
/// report for one price scenario at a time, written to
/// gas-reports/CostEstimate_<scenario>.md. No mocks on the measurement path --
/// same deployment + SPEC Section 4 walkthrough as test/EndToEnd.t.sol.
///
/// One run = one scenario, deliberately -- not a single run producing a 4-column
/// L1-low/normal/high/Base comparison. Gas for the ERC-4337-mediated actions
/// (create/claim/donate) is measurably sensitive to `block.basefee` (EntryPoint's
/// own fee accounting reads it), so reusing one gas measurement across several
/// different price scenarios was subtly wrong. Instead, each L1 scenario pins
/// `block.basefee` to its own price via `vm.fee(...)` before deploying/measuring,
/// so the reported gas is always measured under the exact price it's priced at.
///
/// SPEC Section 8's program population is a `virtual` hook (`_population()`),
/// overridden by `script/InteractiveCostEstimate.s.sol` to prompt for a real
/// population instead of using this script's fixed illustrative example -- that
/// script is a thin overlay on this one, not a separate report engine. See
/// `_reportBasename()`/`_populationIsIllustrative()` for the other two hooks it
/// overrides.
/// Run:
///   forge test --mt test_B3                                                 # prerequisite
///   L1_SCENARIO=low    forge script script/CostEstimate.s.sol                # -> CostEstimate_low.md
///   L1_SCENARIO=normal forge script script/CostEstimate.s.sol                # -> CostEstimate_normal.md
///   L1_SCENARIO=high   forge script script/CostEstimate.s.sol                # -> CostEstimate_high.md
///   forge script script/CostEstimate.s.sol --fork-url https://mainnet.base.org # -> CostEstimate_base.md
contract CostEstimateScript is CostMeasurement {
    // SPEC Section 8 program-scale illustration -- explicitly example figures,
    // not measured. See `_population()`'s doc comment for the real-population
    // override.
    uint256 internal constant DEFAULT_N_CIT = 1000;
    uint256 internal constant DEFAULT_N_CAND = 20;
    uint256 internal constant DEFAULT_N_VEN = 100;
    uint256 internal constant DEFAULT_DONATION_RATE_PERCENT = 50; // d-bar = 0.5
    uint256 internal constant DEFAULT_SPEND_TXS_PER_CANDIDATE = 1;
    uint256 internal constant DEFAULT_REDEEM_TXS_PER_VENDOR = 1;

    struct Population {
        uint256 nCit;
        uint256 nCand;
        uint256 nVen;
        uint256 donationPercent;
        uint256 spendTxsPerCandidate;
        uint256 redeemTxsPerVendor;
    }

    function run() external {
        bool onBase = _onBaseFork();
        PriceScenario memory ps = onBase ? _loadBaseScenario() : _loadL1Scenario(_l1ScenarioLabel());

        (ActionGas memory gas_, L1FeesWei memory l1Fees) = _setup();
        B3Fit memory fit = _refitB3();

        string memory report = _buildReport(gas_, l1Fees, ps, fit);

        string memory path = string.concat("gas-reports/", _reportBasename(), "_", ps.label, ".md");
        vm.writeFile(path, report);
        console2.log(string.concat("Wrote ", path));
    }

    /// @dev Which L1 scenario to measure (ignored when forked -- Base's live fee
    /// is used instead, see `_onBaseFork`/`_loadBaseScenario`). Overridden by
    /// `InteractiveCostEstimateScript` to prompt for it instead of reading
    /// `L1_SCENARIO` from the environment.
    function _l1ScenarioLabel() internal virtual returns (string memory) {
        return vm.envOr("L1_SCENARIO", string("normal"));
    }

    /// @dev Where `_l1ScenarioLabel()`'s value came from, for the report's own
    /// "Source" column -- kept in sync with that function's override.
    function _scenarioSourceLabel() internal pure virtual returns (string memory) {
        return "L1_SCENARIO env var";
    }

    /// @dev SPEC Section 8's illustrative example population. Overridden by
    /// `InteractiveCostEstimateScript` to prompt for a real one instead -- not
    /// `view`/`pure` because that override calls `vm.promptUint`.
    function _population() internal virtual returns (Population memory) {
        return Population({
            nCit: DEFAULT_N_CIT,
            nCand: DEFAULT_N_CAND,
            nVen: DEFAULT_N_VEN,
            donationPercent: DEFAULT_DONATION_RATE_PERCENT,
            spendTxsPerCandidate: DEFAULT_SPEND_TXS_PER_CANDIDATE,
            redeemTxsPerVendor: DEFAULT_REDEEM_TXS_PER_VENDOR
        });
    }

    /// @dev true here: `_population()`'s numbers are a fixed example, not real
    /// data. `InteractiveCostEstimateScript` overrides this to false, since its
    /// population is whatever the user actually typed in.
    function _populationIsIllustrative() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Output filename prefix -- overridden so the interactive variant's
    /// reports don't collide with (or get mistaken for) this script's own.
    function _reportBasename() internal pure virtual returns (string memory) {
        return "CostEstimate";
    }

    // ---- Markdown report ----

    function _buildReport(ActionGas memory gas_, L1FeesWei memory l1Fees, PriceScenario memory ps, B3Fit memory fit)
        internal
        returns (string memory)
    {
        string memory s = string.concat("# CampaignVoucher - Cost Estimate (SPEC Section 7/8) -- scenario: ", ps.label, "\n\n");
        s = string.concat(s, "As of block ", vm.toString(block.number), ", timestamp ", vm.toString(block.timestamp), ".\n\n");
        s = string.concat(s, _methodologySection());
        s = string.concat(s, _parametersSection(ps));
        s = string.concat(s, _perActionSection(gas_, l1Fees, ps));
        s = string.concat(s, _programScaleSection(gas_, ps, fit));
        return s;
    }

    function _methodologySection() internal pure returns (string memory) {
        return string.concat(
            "## Methodology\n\n",
            "Gas figures below are measured directly, with no mocks: the full contract system ",
            "(Groth16 verifier, EntryPoint v0.7, CitizenFactory, CitizenAccount, VoucherPaymaster, ",
            "VoucherNFT) is deployed fresh and driven through SPEC Section 4's canonical walkthrough ",
            "(create/claim/donate sponsored through the real EntryPoint + paymaster; spend/redeem as ",
            "plain EOA calls), identical to `test/EndToEnd.t.sol`. This report covers exactly one price ",
            "scenario -- run this script again with a different `L1_SCENARIO` (or with `--fork-url` for ",
            "Base) to get the others; see the file list under gas-reports/. For an L1 scenario, ",
            "`block.basefee` is pinned via `vm.fee(...)` to that scenario's own price BEFORE deployment, ",
            "so the measured gas reflects that exact price -- not a value borrowed from whatever chain ",
            "happened to be forked (EntryPoint's own fee accounting reads `block.basefee` directly, so ",
            "gas usage is not perfectly price-independent). For Base, the real `GasPriceOracle` ",
            "precompile and live `block.basefee` are used instead (`--fork-url <base-rpc>` required). ",
            "ETH_USD is a supplied parameter (via `.env`, see `.env.example`), not measured or invented ",
            "by the script.\n\n"
        );
    }

    function _parametersSection(PriceScenario memory ps) internal view returns (string memory) {
        string memory s = string.concat(
            "## Parameters\n\n",
            "| Parameter | Value | Source |\n|---|---|---|\n",
            "| Scenario | ", ps.label, " | ", ps.isBase ? "--fork-url (live)" : _scenarioSourceLabel(), " |\n",
            "| ETH_USD | $", vm.toString(ps.ethUsd), " | env var (default 1850, researched 2026-08-04) |\n"
        );
        if (ps.isBase) {
            s = string.concat(
                s,
                "| Base L2 gas price | ", vm.toString(ps.baseL2GasPriceWei), " wei | live, `block.basefee` at block ",
                vm.toString(block.number), " |\n\n"
            );
        } else {
            s = string.concat(
                s,
                "| L1 gas price | ", _fmtGwei(ps.gasPriceMilliGwei), " gwei | env var, pinned via `vm.fee(...)` ",
                "before measurement (researched 2026-08-04) |\n\n"
            );
        }
        return s;
    }

    function _perActionSection(ActionGas memory gas_, L1FeesWei memory l1Fees, PriceScenario memory ps)
        internal
        pure
        returns (string memory)
    {
        string memory s = string.concat(
            "## Per-action cost (SPEC Section 4/7)\n\n",
            "| Action | Gas | Cost (", ps.label, ") |\n",
            "|---|---|---|\n"
        );
        s = string.concat(s, _actionRow("Create", gas_.create, l1Fees.create, ps));
        s = string.concat(s, _actionRow("Claim", gas_.claim, l1Fees.claim, ps));
        s = string.concat(s, _actionRow("Donate", gas_.donate, l1Fees.donate, ps));
        s = string.concat(s, _actionRow("Spend (1)", gas_.spend, l1Fees.spend, ps));
        s = string.concat(s, _actionRow("Redeem (1)", gas_.redeem, l1Fees.redeem, ps));
        s = string.concat(
            s,
            "\n`(1)` on Spend/Redeem means a single voucher, not a fixed per-call cost: both ",
            "`batchTransfer`/`redeem` take an array of voucher IDs and can sweep many at once (SPEC's ",
            "batching requirement at the candidate->vendor and vendor->authority outflows), so this is ",
            "the no-batching baseline, not what a real accumulated sweep costs -- see B3 (`test/gas/",
            "B3_OutflowSlope.t.sol`) for the measured marginal gas/voucher once batched, and Section 8 ",
            "below for that fit applied to a real population.\n\n",
            "(`a_register` measured separately: ", vm.toString(gas_.register), " gas -- used only in Section 8 below.)\n\n"
        );
        return s;
    }

    function _programScaleSection(ActionGas memory gas_, PriceScenario memory ps, B3Fit memory fit) internal returns (string memory) {
        Population memory pop = _population();
        string memory s = string.concat(
            "## Program-scale extrapolation (SPEC Section 8", _populationIsIllustrative() ? ", illustrative" : "", ")\n\n",
            _populationIsIllustrative() ? "Example population, **not measured, not real data**: " : "User-provided population: ",
            vm.toString(pop.nCit), " citizens, ", vm.toString(pop.nCand), " candidates, ", vm.toString(pop.nVen),
            " vendors, ", vm.toString(pop.donationPercent), "% of citizens donate their voucher, each ",
            "candidate/vendor sweeps its accumulated vouchers in ", vm.toString(pop.spendTxsPerCandidate),
            " / ", vm.toString(pop.redeemTxsPerVendor), " batched transaction(s) respectively.",
            _populationIsIllustrative() ? " For a user-chosen population instead, run `script/InteractiveCostEstimate.s.sol`.\n\n" : "\n\n"
        );

        if (!fit.have) {
            return string.concat(
                s,
                "*B3's outflow-slope CSVs (`gas-reports/b3_batchTransfer.csv`/`b3_redeem.csv`) were not ",
                "found -- run `forge test --mt test_B3` first to enable this section.*\n"
            );
        }

        (uint256 sponsorGas, uint256 selfPaidGas, uint256 totalGas) = _programGasBuckets(
            pop.nCit, pop.nCand, pop.nVen, pop.donationPercent, pop.spendTxsPerCandidate, pop.redeemTxsPerVendor, gas_, fit
        );

        s = string.concat(
            s,
            "B3 refit: spend slope=", vm.toString(fit.spendSlope), " gas/voucher, intercept=", vm.toString(fit.spendIntercept),
            "; redeem slope=", vm.toString(fit.redeemSlope), " gas/voucher, intercept=", vm.toString(fit.redeemIntercept), ".\n\n",
            "Sponsor-paid and self-paid are collapsed to two buckets, not three: candidate/vendor ",
            "registration is authority-paid (SPEC Section 3.1's AllowList admin model), the same party ",
            "that funds the paymaster deposit (SPEC Section 3.6) -- so it's counted as sponsor-paid, not ",
            "a separate bucket.\n\n",
            "**Extrapolated total gas: ", vm.toString(totalGas), "**\n\n",
            "| Bucket | Gas | Cost (", ps.label, ") |\n",
            "|---|---|---|\n"
        );
        s = string.concat(s, _bucketRow("Sponsor-paid (create+claim+donate+registration)", sponsorGas, ps));
        s = string.concat(s, _bucketRow("Self-paid (candidate/vendor batched spend+redeem)", selfPaidGas, ps));
        s = string.concat(s, _bucketRow("**Program total**", totalGas, ps));
        return s;
    }

    function _actionRow(string memory name, uint256 gasUsed, uint256 l1FeeWei, PriceScenario memory ps) internal pure returns (string memory) {
        return string.concat(
            "| ", name, " | ", vm.toString(gasUsed), " | ",
            _fmtUsd(_usdMicro(_scenarioCostWei(gasUsed, l1FeeWei, ps), ps.ethUsd)), " |\n"
        );
    }

    function _bucketRow(string memory label, uint256 gasUsed, PriceScenario memory ps) internal pure returns (string memory) {
        return string.concat(
            "| ", label, " | ", vm.toString(gasUsed), " | ",
            _fmtUsd(_usdMicro(_scenarioCostWei(gasUsed, 0, ps), ps.ethUsd)), " |\n"
        );
    }
}
