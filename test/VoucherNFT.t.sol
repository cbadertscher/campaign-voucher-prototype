// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "./utils/Fixture.sol";
import {VoucherNFT} from "../src/VoucherNFT.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VoucherNFTTest is Fixture {
    address internal citizen = makeAddr("citizen");
    address internal candidate = makeAddr("candidate");
    address internal vendor = makeAddr("vendor");

    // ---- claimVoucher ----

    function test_claimVoucher_mintsToRegisteredCitizen() public {
        uint256 id = _mintVoucherTo(citizen);
        assertEq(voucher.ownerOf(id), citizen);
        assertTrue(voucher.hasClaimed(citizen));
    }

    function test_claimVoucher_revertsForUnregisteredCitizen() public {
        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.NotAccreditedCitizen.selector);
        voucher.claimVoucher();
    }

    function test_claimVoucher_revertsOnSecondClaim() public {
        _mintVoucherTo(citizen);
        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.AlreadyClaimed.selector);
        voucher.claimVoucher();
    }

    // ---- donation: citizen -> candidate via transferFrom ----

    function test_donate_citizenToCandidate_succeeds() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);

        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        assertEq(voucher.ownerOf(id), candidate);
    }

    function test_donate_citizenToCitizen_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        address otherCitizen = makeAddr("otherCitizen");
        _registerCitizen(otherCitizen);

        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.transferFrom(citizen, otherCitizen, id);
    }

    function test_donate_toUnregisteredCandidate_reverts() public {
        uint256 id = _mintVoucherTo(citizen);

        vm.prank(citizen);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.transferFrom(citizen, candidate, id);
    }

    // ---- spend: candidate -> vendor via batchTransfer ----

    function test_batchTransfer_candidateToVendor_succeeds() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);
        assertEq(voucher.ownerOf(id), vendor);
    }

    function test_batchTransfer_toNonVendor_reverts() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        vm.expectRevert(VoucherNFT.InvalidTransfer.selector);
        voucher.batchTransfer(vendor, ids);
    }

    function test_batchTransfer_notOwnedId_reverts() public {
        // id is owned by a *different* candidate, so the role transition
        // (candidate -> vendor) is itself valid, isolating the ownership check.
        uint256 id = _mintVoucherTo(citizen);
        address otherCandidate = makeAddr("otherCandidate");
        _registerCandidate(otherCandidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, otherCandidate, id);

        _registerCandidate(candidate);
        _registerVendor(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id; // owned by `otherCandidate`, not `candidate`
        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, candidate, id));
        voucher.batchTransfer(vendor, ids);
    }

    // ---- redeem: vendor -> 0 (burn) ----

    function _voucherAtVendor() internal returns (uint256 id) {
        id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);
    }

    function test_redeem_succeedsForOwningVendor() public {
        uint256 id = _voucherAtVendor();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(vendor);
        voucher.redeem(ids);

        vm.expectRevert();
        voucher.ownerOf(id);
    }

    function test_redeem_revertsForNonVendor() public {
        uint256 id = _voucherAtVendor();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(candidate);
        vm.expectRevert(VoucherNFT.NotVendor.selector);
        voucher.redeem(ids);
    }

    function test_redeem_revertsForNonOwnedId() public {
        uint256 id = _voucherAtVendor();
        address otherVendor = makeAddr("otherVendor");
        _registerVendor(otherVendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(otherVendor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, otherVendor, id, vendor)
        );
        voucher.redeem(ids);
    }

    function test_redeem_revertsForDuplicateId() public {
        uint256 id = _voucherAtVendor();
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        vm.prank(vendor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, vendor, id, address(0))
        );
        voucher.redeem(ids);
    }

    // ---- semantic events ----

    function test_claimVoucher_emitsVoucherClaimed() public {
        _registerCitizen(citizen);
        uint256 expectedId = voucher.nextId();

        vm.expectEmit(address(voucher));
        emit VoucherNFT.VoucherClaimed(citizen, expectedId);

        vm.prank(citizen);
        voucher.claimVoucher();
    }

    function test_donate_emitsVoucherDonated() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);

        vm.expectEmit(address(voucher));
        emit VoucherNFT.VoucherDonated(citizen, candidate, id);

        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
    }

    function test_batchTransfer_emitsVoucherSpent() public {
        uint256 id = _mintVoucherTo(citizen);
        _registerCandidate(candidate);
        vm.prank(citizen);
        voucher.transferFrom(citizen, candidate, id);
        _registerVendor(vendor);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.expectEmit(address(voucher));
        emit VoucherNFT.VoucherSpent(candidate, vendor, id);

        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);
    }

    function test_redeem_emitsVoucherRedeemed() public {
        uint256 id = _voucherAtVendor();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.expectEmit(address(voucher));
        emit VoucherNFT.VoucherRedeemed(vendor, id);

        vm.prank(vendor);
        voucher.redeem(ids);
    }
}
