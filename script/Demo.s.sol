// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AllowList} from "../src/AllowList.sol";
import {CitizenFactory} from "../src/CitizenFactory.sol";
import {CitizenAccount} from "../src/CitizenAccount.sol";
import {VoucherNFT} from "../src/VoucherNFT.sol";
import {VoucherPaymaster} from "../src/VoucherPaymaster.sol";
import {Groth16Verifier} from "../src/verifiers/Groth16Verifier.sol";
import {EntryPoint} from "account-abstraction/contracts/core/EntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOpLib} from "../test/utils/UserOpLib.sol";

/// @notice Local devnet transparency demo: deploys the whole stack and broadcasts
/// SPEC §4's canonical walkthrough as REAL transactions against a running anvil
/// node -- not a Foundry-internal simulation, unlike every prior milestone. Run:
///   anvil
///   forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// Then inspect the real, persisted events with `cast logs` (see README).
contract DemoScript is Script {
    // Anvil's well-known default dev-account keys (public, standard-mnemonic-
    // derived; used only against a local throwaway devnet, never real funds).
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // #0
    uint256 internal constant CANDIDATE_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // #1
    uint256 internal constant VENDOR_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // #2

    // Citizen account's owner key -- reuses credential_owned.json as-is (same key
    // already used across M3/M4/M5's tests/scripts). Only signs off-chain; never
    // broadcasts or needs ETH, since every step it's involved in is sponsored.
    uint256 internal constant OWNER_PK = 0xA11CE;

    uint256 internal constant AUTHORITY_PUBKEY_AX =
        6009826206664631762425195104551483519464780417855034312675013183895652229081;
    uint256 internal constant AUTHORITY_PUBKEY_AY =
        10734004088266146241393102410697198390225666634906567834302254376371681698208;

    address internal deployer;
    address internal candidate;
    address internal vendor;

    EntryPoint internal entryPoint;
    CitizenFactory internal factory;
    AllowList internal citizens;
    VoucherNFT internal voucher;
    VoucherPaymaster internal paymaster;

    address internal citizenAccount;
    uint256 internal tokenId;

    function run() external {
        deployer = vm.addr(DEPLOYER_PK);
        candidate = vm.addr(CANDIDATE_PK);
        vendor = vm.addr(VENDOR_PK);

        _deploy();
        _stepCreate();
        _stepClaim();
        _stepDonate();
        _stepSpend();
        _stepRedeem();

        console2.log("");
        console2.log("Done. Inspect the real events with, e.g.:");
        console2.log("  cast logs --rpc-url http://127.0.0.1:8545 --from-block 0 --address", address(voucher));
        console2.log("  cast logs --rpc-url http://127.0.0.1:8545 --from-block 0 --address", address(factory));
    }

    function _deploy() internal {
        vm.startBroadcast(DEPLOYER_PK);

        Groth16Verifier verifier = new Groth16Verifier();
        entryPoint = new EntryPoint();

        uint256 nonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce + 1);
        citizens = new AllowList(predictedFactory);
        factory = new CitizenFactory(verifier, citizens, 1, AUTHORITY_PUBKEY_AX, AUTHORITY_PUBKEY_AY, entryPoint);
        require(address(factory) == predictedFactory, "factory address prediction mismatch");

        // Factory staking (SPEC §3.3: "document the stake in the deploy script" --
        // the factory writes shared AllowList storage during ERC-4337 validation).
        factory.stake{value: 0.1 ether}(1 days);

        AllowList candidates = new AllowList(deployer);
        AllowList vendors = new AllowList(deployer);
        voucher = new VoucherNFT(deployer, citizens, candidates, vendors, "CampaignVoucher", "CVOU");
        paymaster = new VoucherPaymaster(entryPoint, factory, voucher);
        paymaster.deposit{value: 1 ether}();

        candidates.register(candidate);
        vendors.register(vendor);

        vm.stopBroadcast();

        console2.log("== Deployed ==");
        console2.log("EntryPoint:       ", address(entryPoint));
        console2.log("CitizenFactory:   ", address(factory));
        console2.log("VoucherNFT:       ", address(voucher));
        console2.log("VoucherPaymaster: ", address(paymaster));
        console2.log("candidate (EOA):  ", candidate);
        console2.log("vendor (EOA):     ", vendor);
        console2.log("");
    }

    /// @dev `citizenAccount` must already be set (by _stepCreate, before its own
    /// first call to this) since every op targets it as sender.
    function _signedOp(uint256 nonce, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory userOp =
            UserOpLib.build(citizenAccount, nonce, initCode, callData, UserOpLib.buildPaymasterAndData(address(paymaster)));
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }

    function _predictAccount() internal view returns (address) {
        string memory json = vm.readFile("test/fixtures/credential_owned.json");
        uint256[] memory pubSignals = vm.parseJsonUintArray(json, ".pubSignals");
        bytes32 salt = keccak256(abi.encode(bytes32(pubSignals[2]), address(uint160(pubSignals[3]))));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CitizenAccount).creationCode, abi.encode(address(uint160(pubSignals[3])), entryPoint))
        );
        return vm.computeCreate2Address(salt, initCodeHash, address(factory));
    }

    /// @dev The deployer acts as the bundler here, broadcasting handleOps for real.
    /// @dev Explicit gas stipend, comfortably above the userOp's own declared
    /// limits (1e6 + 1e6 + 1e5 + 2e5 + 2e5 = 2.5e6) plus EntryPoint overhead --
    /// `eth_estimateGas` unreliably underestimates handleOps calls (a known
    /// ERC-4337 gotcha: EntryPoint's internal `call{gas: verificationGasLimit}`-
    /// style sub-calls enforce their own gas requirements in a way a naive
    /// outer-call binary search doesn't correctly discover), so real bundlers
    /// compute the tx gas limit directly from the userOp's fields instead of
    /// trusting estimation, same as here.
    function _submit(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.startBroadcast(DEPLOYER_PK);
        entryPoint.handleOps{gas: 3_000_000}(ops, payable(deployer));
        vm.stopBroadcast();
    }

    function _stepCreate() internal {
        string memory json = vm.readFile("test/fixtures/credential_owned.json");
        bytes memory proof = vm.parseJsonBytes(json, ".proof");
        uint256[] memory pubSignals = vm.parseJsonUintArray(json, ".pubSignals");

        citizenAccount = _predictAccount();
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(CitizenFactory.createAccount.selector, proof, pubSignals));

        _submit(_signedOp(0, initCode, ""));
        console2.log("Step 1/5: account created            ->", citizenAccount);
    }

    function _stepClaim() internal {
        bytes memory callData =
            abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, abi.encodeWithSignature("claimVoucher()"));
        _submit(_signedOp(1, "", callData));
        tokenId = voucher.nextId() - 1;
        console2.log("Step 2/5: voucher claimed, tokenId   ->", tokenId);
    }

    function _stepDonate() internal {
        bytes memory transferCall = abi.encodeWithSignature("transferFrom(address,address,uint256)", citizenAccount, candidate, tokenId);
        bytes memory callData = abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, transferCall);
        _submit(_signedOp(2, "", callData));
        console2.log("Step 3/5: voucher donated to candidate ->", candidate);
    }

    function _stepSpend() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startBroadcast(CANDIDATE_PK);
        voucher.batchTransfer(vendor, ids);
        vm.stopBroadcast();
        console2.log("Step 4/5: voucher spent to vendor      ->", vendor);
    }

    function _stepRedeem() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startBroadcast(VENDOR_PK);
        voucher.redeem(ids);
        vm.stopBroadcast();
        console2.log("Step 5/5: voucher redeemed (burned)");
    }
}
