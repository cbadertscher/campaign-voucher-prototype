// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../utils/Fixture.sol";
import {VoucherNFT} from "../../src/VoucherNFT.sol";

/// @notice I1: vouchers move only 0 -> citizen -> candidate -> vendor -> 0; every
/// other (from,to) role-pair edge reverts.
contract RoleStateMachineTest is Fixture {
    address internal citizen = makeAddr("citizen");
    address internal candidate = makeAddr("candidate");
    address internal vendor = makeAddr("vendor");

    // ---- deterministic table: the two legal edges + every near-miss ----

    function test_I1_mint_zeroToCitizen_ok() public {
        _mintVoucherTo(citizen); // does not revert
    }

    function test_I1_donate_citizenToCandidate_ok() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id); // does not revert
    }

    function test_I1_spend_candidateToVendor_ok() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids); // does not revert
    }

    function test_I1_redeem_vendorToZero_ok() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);

        vm.prank(vendor);
        voucher.redeem(ids); // does not revert
    }

    function test_I1_donate_citizenToCitizen_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        address other = makeAddr("otherCitizen");
        _registerCitizen(other);
        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.transferFrom(citizen, other, id);
    }

    function test_I1_donate_citizenToVendor_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerVendor(vendor);
        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.transferFrom(citizen, vendor, id);
    }

    function test_I1_spend_candidateToCandidate_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        address otherCandidate = makeAddr("otherCandidate");
        _registerCandidate(otherCandidate);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.batchTransfer(otherCandidate, ids);
    }

    function test_I1_spend_candidateToCitizen_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.batchTransfer(citizen, ids); // citizen already claimed, still only a citizen role
    }

    function test_I1_unregistered_cannotClaim() public {
        vm.prank(citizen); // never registered
        vm.expectRevert(VoucherNFT.NotAccreditedCitizen.selector);
        voucher.claimVoucher();
    }

    function test_I1_dualRegistered_from_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);
        // candidate is now ALSO registered as a vendor: dual role
        _registerVendor(candidate);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(VoucherNFT.MultiRole.selector, candidate));
        voucher.batchTransfer(vendor, ids);
    }

    function test_I1_dualRegistered_to_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        // candidate is also registered as a citizen: dual role on the `to` side
        _registerCitizen(candidate);

        vm.prank(citizen);
        vm.expectRevert(abi.encodeWithSelector(VoucherNFT.MultiRole.selector, candidate));
        voucher.transferFrom(citizen, candidate, id);
    }

    // ---- fuzz: derive a synthetic address, register it into an arbitrary role
    // subset on both sides, drive a real voucher into place, assert the outcome
    // matches the policy above ----

    function testFuzz_I1_TransferGate(uint256 seed, bool[3] memory fromRoles, bool[3] memory toRoles) public {
        address from = address(uint160(uint256(keccak256(abi.encode("from", seed)))));
        address to = address(uint160(uint256(keccak256(abi.encode("to", seed)))));
        vm.assume(from != to && from != address(0) && to != address(0));
        vm.assume(from != address(voucher) && to != address(voucher));

        // Get a real voucher into `from`'s hands via the one path that reaches a
        // citizen without pre-existing role registrations: claim it as a citizen,
        // then optionally move it further along the chain before re-registering
        // `from` into the fuzzed role subset (registration is independent of how
        // the voucher got there).
        _registerCitizen(from);
        vm.prank(from);
        voucher.claimVoucher();
        uint256 id = voucher.nextId() - 1;

        // Reset `from`'s registration to exactly the fuzzed subset (it may have
        // been left registered as a citizen above).
        if (!fromRoles[0]) _revokeCitizen(from);
        if (fromRoles[1]) _registerCandidate(from);
        if (fromRoles[2]) _registerVendor(from);

        uint256 fromRoleCount = (fromRoles[0] ? 1 : 0) + (fromRoles[1] ? 1 : 0) + (fromRoles[2] ? 1 : 0);

        if (toRoles[0]) _registerCitizen(to);
        if (toRoles[1]) _registerCandidate(to);
        if (toRoles[2]) _registerVendor(to);
        uint256 toRoleCount = (toRoles[0] ? 1 : 0) + (toRoles[1] ? 1 : 0) + (toRoles[2] ? 1 : 0);

        bool expectOk = fromRoleCount == 1 && toRoleCount == 1
            && ((fromRoles[0] && toRoles[1]) || (fromRoles[1] && toRoles[2]));

        vm.prank(from);
        if (!expectOk) {
            vm.expectRevert();
            voucher.transferFrom(from, to, id);
        } else {
            voucher.transferFrom(from, to, id);
            assertEq(voucher.ownerOf(id), to);
        }
    }

    function _revokeCitizen(address who) internal {
        citizens.revoke(who);
    }
}
