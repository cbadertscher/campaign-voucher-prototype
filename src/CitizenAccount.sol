// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/contracts/core/Helpers.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice ERC-4337 v0.7 account (SPEC §3.4). `validateUserOp` itself is inherited
/// from `BaseAccount` (requires the caller be the EntryPoint, validates the
/// signature, then checks nonce/prefund) -- this contract only supplies
/// `entryPoint()` and `_validateSignature`.
contract CitizenAccount is BaseAccount {
    address public owner;
    IEntryPoint private immutable _entryPoint;

    constructor(address owner_, IEntryPoint entryPoint_) {
        owner = owner_;
        _entryPoint = entryPoint_;
    }

    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    /// @notice onlyEntryPoint (SPEC §3.4).
    function execute(address to, uint256 value, bytes calldata data) external {
        _requireFromEntryPoint();
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev Isolated for a later passkey swap (SPEC §3.4). Deliberately raw
    /// ECDSA.recover(userOpHash, sig) -- NOT the EIP-191-wrapped "Ethereum Signed
    /// Message" hash the eth-infinitism SimpleAccount reference uses -- per SPEC
    /// §1 #6's literal "ecrecover(userOpHash) == owner".
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        override
        returns (uint256)
    {
        if (owner != ECDSA.recover(userOpHash, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    receive() external payable {}
}
