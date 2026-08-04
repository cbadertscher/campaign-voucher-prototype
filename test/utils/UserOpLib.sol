// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @notice Builds minimally-valid PackedUserOperations for tests, with fixed,
/// generously-sized gas limits so tests aren't each hand-rolling the packing.
library UserOpLib {
    function packUints(uint256 hi128, uint256 lo128) internal pure returns (bytes32) {
        return bytes32((hi128 << 128) | lo128);
    }

    /// @param paymasterAndData empty for a self-funded (non-sponsored) op.
    function build(address sender, uint256 nonce, bytes memory initCode, bytes memory callData, bytes memory paymasterAndData)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            accountGasLimits: packUints(1_000_000, 1_000_000), // verificationGasLimit, callGasLimit
            preVerificationGas: 100_000,
            gasFees: packUints(1 gwei, 10 gwei), // maxPriorityFeePerGas, maxFeePerGas
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    function buildPaymasterAndData(address paymaster) internal pure returns (bytes memory) {
        return abi.encodePacked(paymaster, uint128(200_000), uint128(200_000));
    }
}
