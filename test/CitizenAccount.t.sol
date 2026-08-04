// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/contracts/core/Helpers.sol";
import {CitizenAccount} from "../src/CitizenAccount.sol";
import {UserOpLib} from "./utils/UserOpLib.sol";

/// @notice I6: only the owner key authorizes an account's actions.
contract CitizenAccountTest is Test {
    EntryPoint internal entryPoint;
    CitizenAccount internal account;

    uint256 internal ownerPk = 0xA11CE;
    address internal owner;
    uint256 internal attackerPk = 0xBEEF;

    function setUp() public {
        entryPoint = new EntryPoint();
        owner = vm.addr(ownerPk);
        account = new CitizenAccount(owner, entryPoint);
        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{value: 1 ether}(address(account));
    }

    function _dummyUserOp() internal view returns (PackedUserOperation memory) {
        return UserOpLib.build(address(account), 0, "", "", "");
    }

    function _sign(PackedUserOperation memory userOp, uint256 pk) internal view returns (bytes memory) {
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, userOpHash);
        return abi.encodePacked(r, s, v);
    }

    // ---- I6: direct validateUserOp ----

    function test_I6_validateUserOp_succeedsForOwnerSignature() public {
        PackedUserOperation memory userOp = _dummyUserOp();
        userOp.signature = _sign(userOp, ownerPk);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(validationData, SIG_VALIDATION_SUCCESS);
    }

    function test_I6_validateUserOp_failsForForgedSignature() public {
        PackedUserOperation memory userOp = _dummyUserOp();
        userOp.signature = _sign(userOp, attackerPk); // signed by a different key
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(validationData, SIG_VALIDATION_FAILED);
    }

    function test_I6_validateUserOp_revertsForNonEntryPointCaller() public {
        PackedUserOperation memory userOp = _dummyUserOp();
        userOp.signature = _sign(userOp, ownerPk);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectRevert("account: not from EntryPoint");
        account.validateUserOp(userOp, userOpHash, 0);
    }

    // ---- I6: end-to-end through the real EntryPoint ----

    function test_I6_handleOps_revertsForForgedSignature() public {
        PackedUserOperation memory userOp = _dummyUserOp();
        userOp.signature = _sign(userOp, attackerPk);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(ops, payable(address(this)));
    }

    function test_I6_handleOps_succeedsForOwnerSignature() public {
        PackedUserOperation memory userOp = _dummyUserOp();
        userOp.signature = _sign(userOp, ownerPk);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        entryPoint.handleOps(ops, payable(address(this)));
    }

    // ---- execute() gating ----

    function test_execute_revertsForNonEntryPointCaller() public {
        vm.expectRevert("account: not from EntryPoint");
        account.execute(address(0x1234), 0, "");
    }

    receive() external payable {}
}
