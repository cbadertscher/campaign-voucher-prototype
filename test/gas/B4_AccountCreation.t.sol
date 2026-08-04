// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CitizenFactoryHarness} from "../utils/CitizenFactoryHarness.sol";
import {CitizenFactory} from "../../src/CitizenFactory.sol";
import {console2} from "forge-std/console2.sol";

/// @notice B4: real Groth16 verify + CREATE2 deploy + register, gasleft() diff
/// around one createAccount call, same style as B1-B3.
contract B4AccountCreationTest is CitizenFactoryHarness {
    function test_B4_accountCreationGas() public {
        (CitizenFactory factory,) = _deployFactory(1);
        CredentialFixture memory f = _loadFixture("credential_election1");

        uint256 gasBefore = gasleft();
        factory.createAccount(f.proof, f.pubSignals);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("B4 createAccount (real Groth16 verify + CREATE2 + register) gas:", gasUsed);
    }
}
