// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../utils/Fixture.sol";
import {console2} from "forge-std/console2.sol";

/// @notice B2: baseline O(1) gas constants for claimVoucher / donate(1 id) /
/// batchTransfer(1 id) / redeem(1 id), each against fresh (cold-storage) addresses.
contract B2ConstantsTest is Fixture {
    function test_B2_claimVoucher() public {
        address citizen = makeAddr("b2-claim");
        citizens.register(citizen);

        vm.prank(citizen);
        uint256 gasBefore = gasleft();
        voucher.claimVoucher();
        console2.log("B2 claimVoucher gas:", gasBefore - gasleft());
    }

    function test_B2_donate() public {
        (address citizen, uint256 id) = _voucherAtCitizen("b2-donate");
        address candidate = makeAddr("b2-donate-candidate");
        vm.prank(authority);
        candidates.register(candidate);

        vm.prank(citizen);
        uint256 gasBefore = gasleft();
        voucher.transferFrom(citizen, candidate, id);
        console2.log("B2 donate (1 id) gas:", gasBefore - gasleft());
    }

    function test_B2_batchTransfer_1() public {
        (address candidate, uint256 id) = _voucherAtCandidate("b2-batch");
        address vendor = makeAddr("b2-batch-vendor");
        vm.prank(authority);
        vendors.register(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        uint256 gasBefore = gasleft();
        voucher.batchTransfer(vendor, ids);
        console2.log("B2 batchTransfer(1) gas:", gasBefore - gasleft());
    }

    function test_B2_redeem_1() public {
        (address vendor, uint256 id) = _voucherAtVendor("b2-redeem");

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(vendor);
        uint256 gasBefore = gasleft();
        voucher.redeem(ids);
        console2.log("B2 redeem(1) gas:", gasBefore - gasleft());
    }

    function _voucherAtCitizen(string memory label) internal returns (address citizen, uint256 id) {
        citizen = makeAddr(label);
        citizens.register(citizen);
        vm.prank(citizen);
        voucher.claimVoucher();
        id = voucher.nextId() - 1;
    }

    function _voucherAtCandidate(string memory label) internal returns (address candidate, uint256 id) {
        address citizen;
        (citizen, id) = _voucherAtCitizen(string(abi.encodePacked(label, "-citizen")));
        candidate = makeAddr(string(abi.encodePacked(label, "-candidate")));
        vm.prank(authority);
        candidates.register(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
    }

    function _voucherAtVendor(string memory label) internal returns (address vendor, uint256 id) {
        address candidate;
        (candidate, id) = _voucherAtCandidate(label);
        vendor = makeAddr(string(abi.encodePacked(label, "-vendor")));
        vm.prank(authority);
        vendors.register(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);
    }
}
