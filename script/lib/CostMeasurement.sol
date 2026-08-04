// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AllowList} from "../../src/AllowList.sol";
import {CitizenFactory} from "../../src/CitizenFactory.sol";
import {CitizenAccount} from "../../src/CitizenAccount.sol";
import {VoucherNFT} from "../../src/VoucherNFT.sol";
import {VoucherPaymaster} from "../../src/VoucherPaymaster.sol";
import {Groth16Verifier} from "../../src/verifiers/Groth16Verifier.sol";
import {EntryPoint} from "account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOpLib} from "../../test/utils/UserOpLib.sol";

/// @notice Shared deployment, SPEC Section 4 walkthrough measurement, B3 refit and
/// USD/gwei formatting -- used by CostEstimateScript (script/CostEstimate.s.sol)
/// and, through it, InteractiveCostEstimateScript (a thin overlay, see
/// script/InteractiveCostEstimate.s.sol). No `run()` here; the concrete script
/// drives its own flow via `_setup()`/`_loadL1Scenario()`/`_loadBaseScenario()`/
/// `_refitB3()`.
abstract contract CostMeasurement is Script {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant AUTHORITY_PUBKEY_AX =
        6009826206664631762425195104551483519464780417855034312675013183895652229081;
    uint256 internal constant AUTHORITY_PUBKEY_AY =
        10734004088266146241393102410697198390225666634906567834302254376371681698208;

    address internal constant GAS_PRICE_ORACLE = 0x420000000000000000000000000000000000000F;

    EntryPoint internal entryPoint;
    CitizenFactory internal factory;
    AllowList internal citizens;
    AllowList internal candidates;
    AllowList internal vendors;
    VoucherNFT internal voucher;
    VoucherPaymaster internal paymaster;

    // The broadcaster address (script contracts must not rely on address(this), which
    // is ephemeral -- see forge's own lint). DEFAULT_SENDER when run without
    // --sender/--private-key.
    address internal deployer;

    // Scratch state for _measure()'s steps -- storage rather than stack locals to
    // avoid "stack too deep" across the long walkthrough sequence.
    address internal costAccount;
    address internal costCandidate;
    address internal costVendor;
    uint256 internal costTokenId;

    struct ActionGas {
        uint256 create;
        uint256 claim;
        uint256 donate;
        uint256 spend;
        uint256 redeem;
        uint256 register;
    }

    struct L1FeesWei {
        uint256 create;
        uint256 claim;
        uint256 donate;
        uint256 spend;
        uint256 redeem;
        bool available;
    }

    /// @dev One run, one price scenario -- deliberately not a 4-column bundle.
    /// Gas for the ERC-4337-mediated actions (create/claim/donate) is measurably
    /// sensitive to `block.basefee` (EntryPoint's own fee accounting reads it, see
    /// account-abstraction/contracts/core/EntryPoint.sol's `getUserOpGasPrice`), so
    /// reusing one gas measurement across several *different* price scenarios was
    /// subtly wrong -- each scenario now gets its own `vm.fee(...)`-pinned
    /// deployment and measurement (see `_loadL1Scenario`/`_loadBaseScenario`),
    /// so the reported gas is always measured under the exact price it's priced at.
    struct PriceScenario {
        string label; // "low" | "normal" | "high" | "base"
        uint256 ethUsd;
        bool isBase;
        uint256 gasPriceMilliGwei; // L1 scenarios only (milli-gwei, 1000 = 1 gwei)
        uint256 baseL2GasPriceWei; // Base scenario only (live block.basefee, wei)
    }

    struct B3Fit {
        bool have;
        uint256 spendSlope;
        uint256 spendIntercept;
        uint256 redeemSlope;
        uint256 redeemIntercept;
    }

    /// @dev Deploys the full stack (real prank, not broadcast -- see _deploy) and
    /// runs SPEC Section 4's walkthrough once, returning measured gas per action.
    function _setup() internal returns (ActionGas memory gas_, L1FeesWei memory l1Fees) {
        deployer = DEFAULT_SENDER;
        // vm.startPrank (not startBroadcast) -- these scripts never actually
        // broadcast, and startBroadcast triggers forge's real-balance
        // broadcast-simulation pass against the forked chain, which fails for
        // DEFAULT_SENDER's real (near-zero) balance on a live network. Local
        // simulation only needs `deployer` to be the real creator for CREATE
        // address prediction, which startPrank provides without that machinery.
        vm.startPrank(deployer);
        _deploy();
        vm.stopPrank();
        (gas_, l1Fees) = _measure();
    }

    /// @dev Detects a forked OP-stack chain (Base) by checking for the
    /// GasPriceOracle precompile's code -- a bare local EVM has no code at that
    /// fixed address at all. Safe to call before any deployment.
    function _onBaseFork() internal view returns (bool) {
        return GAS_PRICE_ORACLE.code.length > 0;
    }

    /// @dev L1 scenario: no fork needed. Pins `block.basefee` to the scenario's
    /// own price via `vm.fee(...)` -- call this BEFORE `_setup()` so the gas that
    /// gets measured is measured under the exact price this run reports (see
    /// `PriceScenario`'s doc comment for why that matters).
    function _loadL1Scenario(string memory label) internal returns (PriceScenario memory ps) {
        ps.label = label;
        ps.ethUsd = vm.envOr("ETH_USD", uint256(1850));
        ps.isBase = false;
        bytes32 h = keccak256(bytes(label));
        if (h == keccak256(bytes("low"))) {
            ps.gasPriceMilliGwei = vm.envOr("L1_GAS_PRICE_LOW_MGWEI", uint256(100));
        } else if (h == keccak256(bytes("normal"))) {
            ps.gasPriceMilliGwei = vm.envOr("L1_GAS_PRICE_NORMAL_MGWEI", uint256(500));
        } else if (h == keccak256(bytes("high"))) {
            ps.gasPriceMilliGwei = vm.envOr("L1_GAS_PRICE_HIGH_MGWEI", uint256(8000));
        } else {
            revert("L1 scenario must be low, normal, or high");
        }
        vm.fee(ps.gasPriceMilliGwei * 1e6);
    }

    /// @dev Base scenario: real fork required (see `_onBaseFork`). Deliberately
    /// does NOT call `vm.fee` -- the whole point of this scenario is to measure
    /// under Base's real, live basefee, not a pinned stand-in value.
    function _loadBaseScenario() internal view returns (PriceScenario memory ps) {
        ps.label = "base";
        ps.ethUsd = vm.envOr("ETH_USD", uint256(1850));
        ps.isBase = true;
        ps.baseL2GasPriceWei = block.basefee;
    }

    // ---- deployment (same bootstrapping as CitizenFactoryHarness/EndToEnd.t.sol) ----

    function _deploy() internal {
        vm.deal(deployer, 10 ether);

        Groth16Verifier verifier = new Groth16Verifier();
        entryPoint = new EntryPoint();

        uint256 nonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce + 1);
        citizens = new AllowList(predictedFactory);
        factory = new CitizenFactory(verifier, citizens, 1, AUTHORITY_PUBKEY_AX, AUTHORITY_PUBKEY_AY, entryPoint);
        require(address(factory) == predictedFactory, "factory address prediction mismatch");

        candidates = new AllowList(deployer);
        vendors = new AllowList(deployer);
        voucher = new VoucherNFT(deployer, citizens, candidates, vendors, "CampaignVoucher", "CVOU");
        paymaster = new VoucherPaymaster(entryPoint, factory, voucher);

        paymaster.deposit{value: 1 ether}();
    }

    // ---- SPEC Section 4 walkthrough, measured (same steps as test/EndToEnd.t.sol) ----

    function _measure() internal returns (ActionGas memory gas_, L1FeesWei memory l1Fees) {
        costCandidate = makeAddr("cost-candidate");
        costVendor = makeAddr("cost-vendor");
        vm.prank(deployer);
        candidates.register(costCandidate);
        vm.prank(deployer);
        vendors.register(costVendor);

        bytes memory cdCreate;
        (gas_.create, cdCreate) = _stepCreate();
        (l1Fees.create, l1Fees.available) = _tryGetL1Fee(cdCreate);

        bytes memory cdClaim;
        (gas_.claim, cdClaim) = _stepClaim();
        (l1Fees.claim,) = _tryGetL1Fee(cdClaim);

        bytes memory cdDonate;
        (gas_.donate, cdDonate) = _stepDonate();
        (l1Fees.donate,) = _tryGetL1Fee(cdDonate);

        bytes memory cdSpend;
        (gas_.spend, cdSpend) = _stepSpend();
        (l1Fees.spend,) = _tryGetL1Fee(cdSpend);

        bytes memory cdRedeem;
        (gas_.redeem, cdRedeem) = _stepRedeem();
        (l1Fees.redeem,) = _tryGetL1Fee(cdRedeem);

        gas_.register = _stepRegister();
    }

    function _stepCreate() internal returns (uint256 gasUsed, bytes memory cd) {
        string memory json = vm.readFile("test/fixtures/credential_owned.json");
        bytes memory proof = vm.parseJsonBytes(json, ".proof");
        uint256[] memory pubSignals = vm.parseJsonUintArray(json, ".pubSignals");

        bytes32 salt = keccak256(abi.encode(bytes32(pubSignals[2]), address(uint160(pubSignals[3]))));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CitizenAccount).creationCode, abi.encode(address(uint160(pubSignals[3])), entryPoint))
        );
        costAccount = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(CitizenFactory.createAccount.selector, proof, pubSignals));

        (gasUsed, cd) = _submit(_signedOp(costAccount, 0, initCode, ""));
    }

    function _stepClaim() internal returns (uint256 gasUsed, bytes memory cd) {
        bytes memory callData = abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, abi.encodeWithSignature("claimVoucher()"));
        (gasUsed, cd) = _submit(_signedOp(costAccount, 1, "", callData));
        costTokenId = voucher.nextId() - 1;
    }

    function _stepDonate() internal returns (uint256 gasUsed, bytes memory cd) {
        bytes memory transferCall = abi.encodeWithSignature("transferFrom(address,address,uint256)", costAccount, costCandidate, costTokenId);
        bytes memory callData = abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, transferCall);
        (gasUsed, cd) = _submit(_signedOp(costAccount, 2, "", callData));
    }

    function _stepSpend() internal returns (uint256 gasUsed, bytes memory cd) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = costTokenId;
        cd = abi.encodeCall(VoucherNFT.batchTransfer, (costVendor, ids));
        vm.prank(costCandidate);
        uint256 gasBefore = gasleft();
        voucher.batchTransfer(costVendor, ids);
        gasUsed = gasBefore - gasleft();
    }

    function _stepRedeem() internal returns (uint256 gasUsed, bytes memory cd) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = costTokenId;
        cd = abi.encodeCall(VoucherNFT.redeem, (ids));
        vm.prank(costVendor);
        uint256 gasBefore = gasleft();
        voucher.redeem(ids);
        gasUsed = gasBefore - gasleft();
    }

    function _stepRegister() internal returns (uint256 gasUsed) {
        AllowList freshList = new AllowList(deployer);
        address freshRegistrant = makeAddr("cost-fresh-registrant");
        vm.prank(deployer);
        uint256 gasBefore = gasleft();
        freshList.register(freshRegistrant);
        gasUsed = gasBefore - gasleft();
    }

    function _signedOp(address sender, uint256 nonce, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory userOp =
            UserOpLib.build(sender, nonce, initCode, callData, UserOpLib.buildPaymasterAndData(address(paymaster)));
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }

    function _submit(PackedUserOperation memory op) internal returns (uint256 gasUsed, bytes memory txCalldata) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        txCalldata = abi.encodeCall(EntryPoint.handleOps, (ops, payable(deployer)));
        uint256 gasBefore = gasleft();
        entryPoint.handleOps(ops, payable(deployer));
        gasUsed = gasBefore - gasleft();
    }

    /// @dev Calling an address with no code returns (true, "") in the EVM -- checked
    /// via ret.length rather than success, since that's the only way to distinguish
    /// "no GasPriceOracle at this address" (not forked to Base) from a real answer.
    function _tryGetL1Fee(bytes memory txData) internal view returns (uint256 feeWei, bool ok) {
        (bool success, bytes memory ret) = GAS_PRICE_ORACLE.staticcall(abi.encodeWithSignature("getL1Fee(bytes)", txData));
        if (success && ret.length == 32) {
            return (abi.decode(ret, (uint256)), true);
        }
        return (0, false);
    }

    receive() external payable {}

    // ---- SPEC Section 8: refit B3's slope/intercept from its committed CSV output ----

    function _refitB3() internal view returns (B3Fit memory fit) {
        try vm.readFile("gas-reports/b3_batchTransfer.csv") returns (string memory spendCsv) {
            try vm.readFile("gas-reports/b3_redeem.csv") returns (string memory redeemCsv) {
                (int256 sSlope, int256 sIntercept) = _fitOls(spendCsv);
                (int256 rSlope, int256 rIntercept) = _fitOls(redeemCsv);
                fit = B3Fit(true, uint256(sSlope), uint256(sIntercept), uint256(rSlope), uint256(rIntercept));
            } catch {
                fit = B3Fit(false, 0, 0, 0, 0);
            }
        } catch {
            fit = B3Fit(false, 0, 0, 0, 0);
        }
    }

    /// @dev Same 3-line OLS as bench/fit_b3.py, over a "v,gasUsed\n..." CSV.
    function _fitOls(string memory csv) internal pure returns (int256 slope, int256 intercept) {
        string[] memory lines = vm.split(csv, "\n");
        uint256 n = 0;
        int256 sx = 0;
        int256 sy = 0;
        int256 sxx = 0;
        int256 sxy = 0;
        for (uint256 i = 1; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;
            string[] memory parts = vm.split(lines[i], ",");
            int256 x = int256(vm.parseUint(parts[0]));
            int256 y = int256(vm.parseUint(parts[1]));
            n++;
            sx += x;
            sy += y;
            sxx += x * x;
            sxy += x * y;
        }
        int256 nInt = int256(n);
        slope = (nInt * sxy - sx * sy) / (nInt * sxx - sx * sx);
        intercept = (sy - slope * sx) / nInt;
    }

    // ---- USD/gwei formatting (computed in wei throughout; avoids gwei-unit ambiguity) ----

    function _usdMicro(uint256 costWei, uint256 ethUsd) internal pure returns (uint256) {
        return (costWei * ethUsd) / 1e12;
    }

    /// @dev l1DataFeeWei is ignored for L1 scenarios (there's no separate L1 data
    /// fee concept when the action *is* the L1 transaction); it's Base's
    /// `GasPriceOracle.getL1Fee()` result for the Base scenario.
    function _scenarioCostWei(uint256 gasUsed, uint256 l1DataFeeWei, PriceScenario memory ps) internal pure returns (uint256) {
        if (ps.isBase) {
            return gasUsed * ps.baseL2GasPriceWei + l1DataFeeWei;
        }
        return gasUsed * ps.gasPriceMilliGwei * 1e6;
    }

    function _fmtUsd(uint256 microUsd) internal pure returns (string memory) {
        uint256 dollars = microUsd / 1_000_000;
        uint256 frac = microUsd % 1_000_000;
        return string.concat("$", vm.toString(dollars), ".", _padLeft(vm.toString(frac), 6));
    }

    function _fmtGwei(uint256 milliGwei) internal pure returns (string memory) {
        uint256 whole = milliGwei / 1000;
        uint256 frac = milliGwei % 1000;
        return string.concat(vm.toString(whole), ".", _padLeft(vm.toString(frac), 3));
    }

    /// @dev Sponsor-paid (paymaster-funded create/claim/donate, plus authority-paid
    /// candidate/vendor registration -- both ultimately borne by the authority: SPEC
    /// Section 3.6's paymaster deposit and Section 3.1's AllowList.admin, "others:
    /// authority", are the same party) vs. self-paid (candidate/vendor batched
    /// spend/redeem, SPEC Section 3.6 -- never sponsored) gas, for a given
    /// population -- illustrative or user-provided, both go through
    /// CostEstimateScript's `_programScaleSection` (InteractiveCostEstimateScript
    /// only overrides which `Population` it's given, see `_population()`), so
    /// this formula only lives in one place.
    function _programGasBuckets(
        uint256 nCit,
        uint256 nCand,
        uint256 nVen,
        uint256 donationPercent,
        uint256 spendTxsPerCandidate,
        uint256 redeemTxsPerVendor,
        ActionGas memory gas_,
        B3Fit memory fit
    ) internal pure returns (uint256 sponsorGas, uint256 selfPaidGas, uint256 totalGas) {
        uint256 vCit = nCit * donationPercent / 100;
        sponsorGas = nCit * (gas_.create + gas_.claim) + vCit * gas_.donate + (nCand + nVen) * gas_.register;
        selfPaidGas = vCit * (fit.spendSlope + fit.redeemSlope) + nCand * spendTxsPerCandidate * fit.spendIntercept
            + nVen * redeemTxsPerVendor * fit.redeemIntercept;
        totalGas = sponsorGas + selfPaidGas;
    }

    function _padLeft(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory padded = new bytes(width);
        uint256 padLen = width - b.length;
        for (uint256 i = 0; i < padLen; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padLen + i] = b[i];
        }
        return string(padded);
    }
}
