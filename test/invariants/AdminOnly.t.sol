// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../utils/Fixture.sol";
import {AllowList} from "../../src/AllowList.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice I5: citizens.isRegistered is set only by the admin (in M1, only
/// AllowList.register/revoke can flip it, and only the admin can call those;
/// VoucherNFT itself never registers/revokes anyone).
contract AdminOnlyTest is Fixture {
    address internal citizen = makeAddr("citizen");
    address internal candidate = makeAddr("candidate");
    address internal vendor = makeAddr("vendor");

    function test_I5_onlyAdminCanRegister_citizens() public {
        vm.prank(citizen);
        vm.expectRevert(AllowList.NotAdmin.selector);
        citizens.register(citizen);
    }

    function test_I5_onlyAdminCanRegister_candidates() public {
        vm.prank(candidate);
        vm.expectRevert(AllowList.NotAdmin.selector);
        candidates.register(candidate);
    }

    function test_I5_onlyAdminCanRegister_vendors() public {
        vm.prank(vendor);
        vm.expectRevert(AllowList.NotAdmin.selector);
        vendors.register(vendor);
    }

    /// @dev Drives a full claim/donate/spend/redeem sequence and asserts VoucherNFT
    /// itself never emits Registered/Revoked from any of the three AllowLists —
    /// it only ever reads via isRegistered (a view function).
    function test_I5_voucherNFTNeverRegistersOrRevokes() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        _registerVendor(vendor);

        vm.recordLogs();

        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);

        vm.prank(vendor);
        voucher.redeem(ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 registeredTopic = keccak256("Registered(address)");
        bytes32 revokedTopic = keccak256("Revoked(address)");

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(citizens) || logs[i].topics[0] != registeredTopic);
            assertTrue(logs[i].emitter != address(citizens) || logs[i].topics[0] != revokedTopic);
            assertTrue(logs[i].emitter != address(candidates) || logs[i].topics[0] != registeredTopic);
            assertTrue(logs[i].emitter != address(candidates) || logs[i].topics[0] != revokedTopic);
            assertTrue(logs[i].emitter != address(vendors) || logs[i].topics[0] != registeredTopic);
            assertTrue(logs[i].emitter != address(vendors) || logs[i].topics[0] != revokedTopic);
        }
    }
}
