// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CitizenFactoryHarness} from "./utils/CitizenFactoryHarness.sol";
import {UserOpLib} from "./utils/UserOpLib.sol";
import {AllowList} from "../src/AllowList.sol";
import {CitizenFactory} from "../src/CitizenFactory.sol";
import {CitizenAccount} from "../src/CitizenAccount.sol";
import {VoucherNFT} from "../src/VoucherNFT.sol";
import {VoucherPaymaster} from "../src/VoucherPaymaster.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @notice I7: the paymaster sponsors gas only for approved targets (SPEC §3.6).
contract VoucherPaymasterTest is CitizenFactoryHarness {
    // Address of test private key 0xA11CE -- matches
    // circuits/scripts/gen_fixture.js's KNOWN_KEY_OWNER_ADDRESS, baked into the
    // credential_owned fixture's `owner` public signal.
    uint256 internal constant OWNED_ACCOUNT_PK = 0xA11CE;

    CitizenFactory internal factory;
    AllowList internal citizens;
    AllowList internal candidates;
    AllowList internal vendors;
    VoucherNFT internal voucher;
    VoucherPaymaster internal paymaster;

    function setUp() public override {
        super.setUp();
        (factory, citizens) = _deployFactory(1);
        candidates = new AllowList(address(this));
        vendors = new AllowList(address(this));
        voucher = new VoucherNFT(address(this), citizens, candidates, vendors, "CampaignVoucher", "CVOU");
        paymaster = new VoucherPaymaster(entryPoint, factory, voucher);

        vm.deal(address(this), 10 ether);
        paymaster.deposit{value: 1 ether}();
    }

    function _createOwnedAccount() internal returns (address account) {
        CredentialFixture memory f = _loadFixture("credential_owned");
        account = factory.createAccount(f.proof, f.pubSignals);
    }

    function _signedOp(address account, bytes memory callData) internal view returns (PackedUserOperation memory) {
        PackedUserOperation memory userOp =
            UserOpLib.build(account, 0, "", callData, UserOpLib.buildPaymasterAndData(address(paymaster)));
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNED_ACCOUNT_PK, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }

    /// @dev The account itself is never funded -- success here is only possible
    /// because the paymaster's deposit covers gas, proving sponsorship actually
    /// happened rather than the account silently self-paying.
    function test_I7_sponsorsExecuteCallTargetingVoucherNFT() public {
        address account = _createOwnedAccount();
        bytes memory callData =
            abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, abi.encodeWithSignature("claimVoucher()"));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _signedOp(account, callData);

        entryPoint.handleOps(ops, payable(address(this)));

        assertTrue(voucher.hasClaimed(account));
    }

    function test_I7_rejectsExecuteCallTargetingUnrelatedContract() public {
        address account = _createOwnedAccount();
        bytes memory callData =
            abi.encodeWithSelector(CitizenAccount.execute.selector, address(candidates), 0, abi.encodeWithSignature("isRegistered(address)", account));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _signedOp(account, callData);

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA34 signature error"));
        entryPoint.handleOps(ops, payable(address(this)));
    }

    /// @dev Full stack, first time together: real ZK proof verified as part of a
    /// real EntryPoint initCode-triggered creation, sponsored by the paymaster.
    function test_I7_sponsorsAccountCreation() public {
        CredentialFixture memory f = _loadFixture("credential_owned");

        bytes32 salt = keccak256(abi.encode(bytes32(f.pubSignals[2]), address(uint160(f.pubSignals[3]))));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(CitizenAccount).creationCode, abi.encode(address(uint160(f.pubSignals[3])), entryPoint)));
        address predictedAccount = vm.computeCreate2Address(salt, initCodeHash, address(factory));

        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(CitizenFactory.createAccount.selector, f.proof, f.pubSignals));

        PackedUserOperation memory userOp = UserOpLib.build(
            predictedAccount, 0, initCode, "", UserOpLib.buildPaymasterAndData(address(paymaster))
        );
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNED_ACCOUNT_PK, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        entryPoint.handleOps(ops, payable(address(this)));

        assertTrue(citizens.isRegistered(predictedAccount));
    }

    receive() external payable {}
}
