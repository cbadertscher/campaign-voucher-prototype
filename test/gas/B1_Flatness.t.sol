// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Fixture} from "../utils/Fixture.sol";

/// @notice B1: donation gas must be invariant to |citizens| (population size).
/// Registers 50 then 5,000 citizens into the same AllowList and measures one
/// fresh (never-before-touched) donation's gas at each point — a plain mapping
/// lookup's cost doesn't depend on how many other entries exist.
contract B1FlatnessTest is Fixture {
    /// @dev A tight tolerance, not exact equality: `-vvvv` tracing shows the actual
    /// `VoucherNFT::transferFrom` call executes byte-identical internal opcodes at
    /// both population sizes (identical per-check costs, identical 38830 total) —
    /// the few hundred gas of residual delta between the two `gasleft()` deltas
    /// comes from this *test harness's* own memory bookkeeping (the population-5000
    /// fill loop expands the shared call frame's memory well before the measured
    /// call), not from AllowList/VoucherNFT's logic depending on population size.
    function test_B1_donationGasFlatToPopulation() public {
        uint256 gasAt50 = _fillAndMeasureDonation(50, 0);
        uint256 gasAt5000 = _fillAndMeasureDonation(5000, 50);
        assertApproxEqAbs(gasAt50, gasAt5000, 1000);
    }

    function _fillAndMeasureDonation(uint256 targetPopulation, uint256 alreadyFilled)
        internal
        returns (uint256 gasUsed)
    {
        for (uint256 i = alreadyFilled; i < targetPopulation; i++) {
            citizens.register(_synthetic("filler", i));
        }

        address citizen = _synthetic("measured-citizen", targetPopulation);
        address candidate = _synthetic("measured-candidate", targetPopulation);
        citizens.register(citizen);
        vm.prank(authority);
        candidates.register(candidate);

        vm.prank(citizen);
        voucher.claimVoucher();
        uint256 id = voucher.nextId() - 1;

        vm.prank(citizen);
        uint256 gasBefore = gasleft();
        voucher.transferFrom(citizen, candidate, id);
        gasUsed = gasBefore - gasleft();
    }

    function _synthetic(string memory label, uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(label, i)))));
    }
}
