// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AllowList} from "./AllowList.sol";
import {CitizenAccount} from "./CitizenAccount.sol";
import {Groth16Verifier} from "./verifiers/Groth16Verifier.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @notice The single ZK site (SPEC §3.3): verifies a credential proof exactly
/// once, consumes its election-scoped nullifier, deploys a CitizenAccount, and
/// registers it as an accredited citizen. One instance per election.
contract CitizenFactory {
    Groth16Verifier public immutable verifier;
    AllowList public immutable citizens; // citizens.admin == address(this)
    uint256 public immutable electionId;
    uint256 public immutable authorityPubKeyAx;
    uint256 public immutable authorityPubKeyAy;
    IEntryPoint public immutable entryPoint;

    mapping(bytes32 => bool) public nullifierSpent;

    event AccountCreated(address indexed account, bytes32 indexed nullifier, address indexed owner);

    error WrongElection(uint256 got, uint256 expected);
    error NullifierAlreadySpent(bytes32 nullifier);
    error WrongAuthority();
    error InvalidProof();

    constructor(
        Groth16Verifier verifier_,
        AllowList citizens_,
        uint256 electionId_,
        uint256 authorityPubKeyAx_,
        uint256 authorityPubKeyAy_,
        IEntryPoint entryPoint_
    ) {
        verifier = verifier_;
        citizens = citizens_;
        electionId = electionId_;
        authorityPubKeyAx = authorityPubKeyAx_;
        authorityPubKeyAy = authorityPubKeyAy_;
        entryPoint = entryPoint_;
    }

    /// @notice Factory staking (SPEC §3.3): the factory writes shared AllowList
    /// storage during ERC-4337 validation (via `createAccount` called as
    /// `initCode`), so ERC-7562 requires it be a staked entity for bundlers to
    /// accept its account-creation ops. Permissionless -- anyone may fund it.
    function stake(uint32 unstakeDelaySec) external payable {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @dev pubSignals order (fixed by circuits/credential.circom's `main` component):
    /// [authorityPubKeyAx, authorityPubKeyAy, nullifier, owner, electionId].
    function createAccount(bytes calldata proof, uint256[] calldata pubSignals) external returns (address account) {
        require(pubSignals.length == 5, "bad pubSignals length");

        uint256 pubAx = pubSignals[0];
        uint256 pubAy = pubSignals[1];
        uint256 nullifierUint = pubSignals[2];
        uint256 ownerUint = pubSignals[3];
        uint256 provedElectionId = pubSignals[4];

        if (pubAx != authorityPubKeyAx || pubAy != authorityPubKeyAy) revert WrongAuthority();
        if (provedElectionId != electionId) revert WrongElection(provedElectionId, electionId);

        bytes32 nullifier = bytes32(nullifierUint);
        if (nullifierSpent[nullifier]) revert NullifierAlreadySpent(nullifier);

        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c) =
            abi.decode(proof, (uint256[2], uint256[2][2], uint256[2]));
        uint256[5] memory fixedSignals = [pubAx, pubAy, nullifierUint, ownerUint, provedElectionId];
        if (!verifier.verifyProof(a, b, c, fixedSignals)) revert InvalidProof();

        nullifierSpent[nullifier] = true;

        // forge-lint: disable-next-line(unsafe-typecast)
        address owner = address(uint160(ownerUint)); // circuit binds `owner` as a public signal; truncation is the standard field-to-address convention (same as ecrecover)
        bytes32 salt = keccak256(abi.encode(nullifier, owner));
        account = address(new CitizenAccount{salt: salt}(owner, entryPoint));

        citizens.register(account);
        emit AccountCreated(account, nullifier, owner);
    }
}
