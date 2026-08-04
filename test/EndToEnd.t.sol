// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {CitizenFactoryHarness} from "./utils/CitizenFactoryHarness.sol";
import {UserOpLib} from "./utils/UserOpLib.sol";
import {AllowList} from "../src/AllowList.sol";
import {CitizenFactory} from "../src/CitizenFactory.sol";
import {CitizenAccount} from "../src/CitizenAccount.sol";
import {VoucherNFT} from "../src/VoucherNFT.sol";
import {VoucherPaymaster} from "../src/VoucherPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @notice B5 (SPEC §4/§6): the canonical end-to-end walkthrough -- sponsored
/// create -> claim -> donate -> spend -> redeem for one voucher's full life, real
/// EntryPoint + paymaster + verifier throughout, no mocks. Per-step + total gas.
contract EndToEndTest is CitizenFactoryHarness {
    uint256 internal constant OWNER_PK = 0xA11CE;

    CitizenFactory internal factory;
    AllowList internal citizens;
    AllowList internal candidates;
    AllowList internal vendors;
    VoucherNFT internal voucher;
    VoucherPaymaster internal paymaster;

    address internal candidate = makeAddr("candidate");
    address internal vendor = makeAddr("vendor");

    function setUp() public override {
        super.setUp();
        (factory, citizens) = _deployFactory(1);
        candidates = new AllowList(address(this));
        vendors = new AllowList(address(this));
        voucher = new VoucherNFT(address(this), citizens, candidates, vendors, "CampaignVoucher", "CVOU");
        paymaster = new VoucherPaymaster(entryPoint, factory, voucher);

        vm.deal(address(this), 10 ether);
        paymaster.deposit{value: 1 ether}();
        candidates.register(candidate);
        vendors.register(vendor);
    }

    function _signedOp(address sender, uint256 nonce, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory userOp =
            UserOpLib.build(sender, nonce, initCode, callData, UserOpLib.buildPaymasterAndData(address(paymaster)));
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }

    function _submit(PackedUserOperation memory op) internal returns (uint256 gasUsed) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        uint256 gasBefore = gasleft();
        entryPoint.handleOps(ops, payable(address(this)));
        gasUsed = gasBefore - gasleft();
    }

    function test_B5_endToEndWalkthrough() public {
        CredentialFixture memory f = _loadFixture("credential_owned");

        // 1. Create: sponsored userOp with initCode -- factory verifies the real
        // Groth16 proof, consumes the nullifier, deploys the account, registers it.
        bytes32 salt = keccak256(abi.encode(bytes32(f.pubSignals[2]), address(uint160(f.pubSignals[3]))));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CitizenAccount).creationCode, abi.encode(address(uint160(f.pubSignals[3])), entryPoint))
        );
        address account = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSelector(CitizenFactory.createAccount.selector, f.proof, f.pubSignals));
        uint256 gasCreate = _submit(_signedOp(account, 0, initCode, ""));

        // 2. Claim: sponsored, owner-signed userOp -> VoucherNFT.claimVoucher().
        uint256 gasClaim = _submit(
            _signedOp(account, 1, "", abi.encodeWithSelector(CitizenAccount.execute.selector, address(voucher), 0, abi.encodeWithSignature("claimVoucher()")))
        );
        uint256 tokenId = voucher.nextId() - 1;

        // 3. Donate: sponsored, owner-signed -> account calls transferFrom(citizen, candidate, id).
        uint256 gasDonate = _submit(
            _signedOp(
                account,
                2,
                "",
                abi.encodeWithSelector(
                    CitizenAccount.execute.selector,
                    address(voucher),
                    0,
                    abi.encodeWithSignature("transferFrom(address,address,uint256)", account, candidate, tokenId)
                )
            )
        );

        // 4. Spend: candidate calls batchTransfer(vendor, ids) -- EOA, not sponsored.
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(candidate);
        uint256 gasBeforeSpend = gasleft();
        voucher.batchTransfer(vendor, ids);
        uint256 gasSpend = gasBeforeSpend - gasleft();

        // 5. Redeem: vendor calls redeem(ids) -- EOA, not sponsored.
        vm.prank(vendor);
        uint256 gasBeforeRedeem = gasleft();
        voucher.redeem(ids);
        uint256 gasRedeem = gasBeforeRedeem - gasleft();

        uint256 total = gasCreate + gasClaim + gasDonate + gasSpend + gasRedeem;

        console2.log("B5 create gas:", gasCreate);
        console2.log("B5 claim  gas:", gasClaim);
        console2.log("B5 donate gas:", gasDonate);
        console2.log("B5 spend  gas:", gasSpend);
        console2.log("B5 redeem gas:", gasRedeem);
        console2.log("B5 TOTAL  gas:", total);

        assertTrue(citizens.isRegistered(account));
        assertTrue(voucher.hasClaimed(account));
    }

    receive() external payable {}
}
