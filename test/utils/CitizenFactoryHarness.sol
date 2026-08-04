// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllowList} from "../../src/AllowList.sol";
import {CitizenFactory} from "../../src/CitizenFactory.sol";
import {Groth16Verifier} from "../../src/verifiers/Groth16Verifier.sol";
import {EntryPoint} from "account-abstraction/contracts/core/EntryPoint.sol";

/// @notice Shared harness for CitizenFactory tests (declares no test_ functions
/// itself, so subclasses don't redundantly re-run each other's cases).
contract CitizenFactoryHarness is Test {
    // Must match circuits/scripts/gen_fixture.js's AUTHORITY_PRV-derived pubkey.
    uint256 internal constant AUTHORITY_PUBKEY_AX =
        6009826206664631762425195104551483519464780417855034312675013183895652229081;
    uint256 internal constant AUTHORITY_PUBKEY_AY =
        10734004088266146241393102410697198390225666634906567834302254376371681698208;

    struct CredentialFixture {
        bytes proof;
        uint256[] pubSignals;
    }

    Groth16Verifier internal verifier;
    EntryPoint internal entryPoint;

    function setUp() public virtual {
        verifier = new Groth16Verifier();
        entryPoint = new EntryPoint();
    }

    function _loadFixture(string memory name) internal view returns (CredentialFixture memory f) {
        string memory json = vm.readFile(string.concat("test/fixtures/", name, ".json"));
        f.proof = vm.parseJsonBytes(json, ".proof");
        f.pubSignals = vm.parseJsonUintArray(json, ".pubSignals");
    }

    /// @dev citizens' admin must equal the factory's own address (SPEC §3.3), but the
    /// factory's constructor takes `citizens` as an immutable — so we predict the
    /// factory's address (same deployer, next nonce) before deploying AllowList.
    function _deployFactory(uint256 electionId) internal returns (CitizenFactory factory, AllowList citizens) {
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        citizens = new AllowList(predicted);
        factory = new CitizenFactory(verifier, citizens, electionId, AUTHORITY_PUBKEY_AX, AUTHORITY_PUBKEY_AY, entryPoint);
        assertEq(address(factory), predicted, "factory address prediction mismatch");
    }
}
