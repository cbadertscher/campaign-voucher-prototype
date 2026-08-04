// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllowList} from "../src/AllowList.sol";

contract AllowListTest is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal eve = makeAddr("eve");

    AllowList internal list;

    function setUp() public {
        list = new AllowList(admin);
    }

    function test_register_setsIsRegistered() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(list));
        emit AllowList.Registered(alice);
        list.register(alice);
        assertTrue(list.isRegistered(alice));
    }

    function test_revoke_clearsIsRegistered() public {
        vm.startPrank(admin);
        list.register(alice);
        vm.expectEmit(true, false, false, false, address(list));
        emit AllowList.Revoked(alice);
        list.revoke(alice);
        vm.stopPrank();
        assertFalse(list.isRegistered(alice));
    }

    function test_register_revertsForNonAdmin() public {
        vm.prank(eve);
        vm.expectRevert(AllowList.NotAdmin.selector);
        list.register(alice);
    }

    function test_revoke_revertsForNonAdmin() public {
        vm.prank(admin);
        list.register(alice);

        vm.prank(eve);
        vm.expectRevert(AllowList.NotAdmin.selector);
        list.revoke(alice);
    }
}
