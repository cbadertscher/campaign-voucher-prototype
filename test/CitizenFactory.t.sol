// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CitizenFactoryHarness} from "./utils/CitizenFactoryHarness.sol";
import {AllowList} from "../src/AllowList.sol";
import {CitizenFactory} from "../src/CitizenFactory.sol";

/// @notice I2: one account per credential per election. Uses real Groth16 proofs
/// (circuits/credential.circom, committed fixtures under test/fixtures/) — no mocks
/// on this path.
contract CitizenFactoryTest is CitizenFactoryHarness {
    function test_createAccount_happyPath() public {
        (CitizenFactory factory, AllowList citizens) = _deployFactory(1);
        CredentialFixture memory f = _loadFixture("credential_election1");

        address account = factory.createAccount(f.proof, f.pubSignals);

        assertTrue(citizens.isRegistered(account));
        assertTrue(factory.nullifierSpent(bytes32(f.pubSignals[2])));
    }

    function test_createAccount_revertsOnWrongElection() public {
        (CitizenFactory factory,) = _deployFactory(1); // scoped to election 1
        CredentialFixture memory f = _loadFixture("credential_election2"); // proved for election 2

        vm.expectRevert(abi.encodeWithSelector(CitizenFactory.WrongElection.selector, 2, 1));
        factory.createAccount(f.proof, f.pubSignals);
    }

    function test_createAccount_revertsOnDoubleSpend() public {
        (CitizenFactory factory,) = _deployFactory(1);
        CredentialFixture memory f = _loadFixture("credential_election1");

        factory.createAccount(f.proof, f.pubSignals);

        vm.expectRevert(abi.encodeWithSelector(CitizenFactory.NullifierAlreadySpent.selector, bytes32(f.pubSignals[2])));
        factory.createAccount(f.proof, f.pubSignals);
    }

    /// @dev I2 unlinkability: the same credential (secret `s`) proved for a different
    /// election yields a different, unrelated nullifier, and succeeds independently
    /// in a factory scoped to that election.
    function test_createAccount_differentElection_differentNullifier() public {
        (CitizenFactory factory1,) = _deployFactory(1);
        (CitizenFactory factory2,) = _deployFactory(2);

        CredentialFixture memory f1 = _loadFixture("credential_election1");
        CredentialFixture memory f2 = _loadFixture("credential_election2");

        assertTrue(f1.pubSignals[2] != f2.pubSignals[2], "nullifiers must differ across elections");

        factory1.createAccount(f1.proof, f1.pubSignals);
        factory2.createAccount(f2.proof, f2.pubSignals);
    }

    /// @dev The circuit only checks that (R8,S) is *a* valid signature under whatever
    /// authorityPubKey is supplied as a public input — it doesn't pin a specific key.
    /// Only CitizenFactory's on-chain comparison does. This fixture's proof is fully
    /// valid (signed and proved correctly) under a *different* authority keypair, so
    /// it must still be rejected.
    function test_createAccount_revertsOnRogueAuthority() public {
        (CitizenFactory factory,) = _deployFactory(1);
        CredentialFixture memory f = _loadFixture("credential_rogue_authority");

        vm.expectRevert(CitizenFactory.WrongAuthority.selector);
        factory.createAccount(f.proof, f.pubSignals);
    }

    /// @dev "Factory staking" (SPEC §3.3, M3 milestone): the factory writes shared
    /// AllowList storage during ERC-4337 validation, so ERC-7562 requires it be a
    /// staked entity for bundlers to accept its account-creation ops. That rule is
    /// bundler-only, not enforced on-chain (confirmed against the real EntryPoint
    /// source), so this only proves staking mechanically works, not that skipping
    /// it would be rejected.
    function test_stake_increasesFactoryStakeInEntryPoint() public {
        (CitizenFactory factory,) = _deployFactory(1);

        vm.deal(address(this), 1 ether);
        factory.stake{value: 1 ether}(1 days);

        assertEq(entryPoint.getDepositInfo(address(factory)).stake, 1 ether);
        assertTrue(entryPoint.getDepositInfo(address(factory)).staked);
        assertEq(entryPoint.getDepositInfo(address(factory)).unstakeDelaySec, 1 days);
    }
}
