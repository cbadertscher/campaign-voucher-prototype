// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllowList} from "../../src/AllowList.sol";
import {VoucherNFT} from "../../src/VoucherNFT.sol";

/// @notice Shared M1 test harness. `citizens`' admin is this contract itself,
/// standing in for the CitizenFactory that M2 will add; VoucherNFT/AllowList need
/// zero code changes when a real factory takes over that role later.
contract Fixture is Test {
    address internal authority = makeAddr("authority");

    AllowList internal citizens;
    AllowList internal candidates;
    AllowList internal vendors;
    VoucherNFT internal voucher;

    function setUp() public virtual {
        citizens = new AllowList(address(this));
        candidates = new AllowList(authority);
        vendors = new AllowList(authority);
        voucher = new VoucherNFT(authority, citizens, candidates, vendors, "CampaignVoucher", "CVOU");
    }

    function _registerCitizen(address who) internal {
        citizens.register(who);
    }

    function _registerCandidate(address who) internal {
        vm.prank(authority);
        candidates.register(who);
    }

    function _registerVendor(address who) internal {
        vm.prank(authority);
        vendors.register(who);
    }

    /// @dev Registers `citizen` and claims a voucher for them, returning the minted id.
    /// Always drives real state transitions rather than forging ERC-721 storage.
    function _mintVoucherTo(address citizen) internal returns (uint256 id) {
        _registerCitizen(citizen);
        vm.prank(citizen);
        voucher.claimVoucher();
        return voucher.nextId() - 1;
    }
}
