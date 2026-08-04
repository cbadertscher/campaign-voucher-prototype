// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../utils/Fixture.sol";
import {console2} from "forge-std/console2.sol";

/// @notice B3: batchTransfer/redeem gas vs v invocation size, written to CSV for
/// bench/fit_b3.py's linear fit and v_max derivation.
contract B3OutflowSlopeTest is Fixture {
    uint256[6] internal VS = [1, 5, 10, 25, 50, 100];

    function test_B3_batchTransferSlope() public {
        string memory path = "gas-reports/b3_batchTransfer.csv";
        vm.writeFile(path, "v,gasUsed\n");

        for (uint256 i = 0; i < VS.length; i++) {
            uint256 v = VS[i];
            (address candidate, uint256[] memory ids) = _vouchersAtCandidate(v);
            address vendor = makeAddr(string(abi.encodePacked("b3-batch-vendor-", vm.toString(v))));
            vm.prank(authority);
            vendors.register(vendor);

            vm.prank(candidate);
            uint256 gasBefore = gasleft();
            voucher.batchTransfer(vendor, ids);
            uint256 gasUsed = gasBefore - gasleft();

            console2.log("B3 batchTransfer v =", v, gasUsed);
            vm.writeLine(path, string(abi.encodePacked(vm.toString(v), ",", vm.toString(gasUsed))));
        }
    }

    function test_B3_redeemSlope() public {
        string memory path = "gas-reports/b3_redeem.csv";
        vm.writeFile(path, "v,gasUsed\n");

        for (uint256 i = 0; i < VS.length; i++) {
            uint256 v = VS[i];
            (address vendor, uint256[] memory ids) = _vouchersAtVendor(v);

            vm.prank(vendor);
            uint256 gasBefore = gasleft();
            voucher.redeem(ids);
            uint256 gasUsed = gasBefore - gasleft();

            console2.log("B3 redeem v =", v, gasUsed);
            vm.writeLine(path, string(abi.encodePacked(vm.toString(v), ",", vm.toString(gasUsed))));
        }
    }

    function _vouchersAtCandidate(uint256 v) internal returns (address candidate, uint256[] memory ids) {
        candidate = makeAddr(string(abi.encodePacked("b3-candidate-", vm.toString(v))));
        vm.prank(authority);
        candidates.register(candidate);

        ids = new uint256[](v);
        for (uint256 j = 0; j < v; j++) {
            address citizen = address(uint160(uint256(keccak256(abi.encode("b3-citizen", v, j)))));
            citizens.register(citizen);
            vm.prank(citizen);
            voucher.claimVoucher();
            uint256 id = voucher.nextId() - 1;
            vm.prank(citizen);
            voucher.transferFrom(citizen, candidate, id);
            ids[j] = id;
        }
    }

    function _vouchersAtVendor(uint256 v) internal returns (address vendor, uint256[] memory ids) {
        address candidate;
        (candidate, ids) = _vouchersAtCandidate(v);
        vendor = makeAddr(string(abi.encodePacked("b3-redeem-vendor-", vm.toString(v))));
        vm.prank(authority);
        vendors.register(vendor);

        vm.prank(candidate);
        voucher.batchTransfer(vendor, ids);
    }
}
