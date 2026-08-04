// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BasePaymaster} from "account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "account-abstraction/contracts/core/Helpers.sol";
import {CitizenFactory} from "./CitizenFactory.sol";
import {VoucherNFT} from "./VoucherNFT.sol";
import {CitizenAccount} from "./CitizenAccount.sol";

/// @notice ERC-4337 v0.7 paymaster (SPEC §3.6). Sponsors only ops whose real
/// destination is the factory (account creation) or VoucherNFT (execute() calls);
/// rejects everything else (anti-griefing). deposit()/addStake()/getDeposit() are
/// inherited from BasePaymaster for free; owner = whoever deploys it (the
/// authority, per SPEC's "funded by an authority deposit").
contract VoucherPaymaster is BasePaymaster {
    CitizenFactory public immutable factory;
    VoucherNFT public immutable voucher;

    constructor(IEntryPoint entryPoint_, CitizenFactory factory_, VoucherNFT voucher_)
        BasePaymaster(entryPoint_)
    {
        factory = factory_;
        voucher = voucher_;
    }

    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        bool allowed;
        if (userOp.initCode.length > 0) {
            // creation op: initCode's embedded factory address must be ours
            allowed = address(bytes20(userOp.initCode[0:20])) == address(factory);
        } else if (userOp.callData.length >= 4 && bytes4(userOp.callData[0:4]) == CitizenAccount.execute.selector) {
            // execute(dest, value, data): decode the real destination
            (address dest,,) = abi.decode(userOp.callData[4:], (address, uint256, bytes));
            allowed = dest == address(voucher);
        } else {
            allowed = false;
        }
        return ("", _packValidationData(!allowed, 0, 0));
    }
}
