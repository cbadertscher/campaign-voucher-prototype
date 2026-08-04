// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AllowList} from "./AllowList.sol";

/// @notice Discrete ERC-721 campaign-finance vouchers. No verifier, no nullifier:
/// accreditation is assumed to have already happened (via CitizenFactory, added in
/// M2) by the time an address appears in the citizens AllowList. This contract only
/// enforces the transfer-rule state machine and the one-voucher-per-account claim.
contract VoucherNFT is ERC721 {
    enum Role {
        None,
        Citizen,
        Candidate,
        Vendor
    }

    address public immutable authority;
    AllowList public immutable citizens;
    AllowList public immutable candidates;
    AllowList public immutable vendors;

    mapping(address => bool) public hasClaimed;
    uint256 public nextId;

    event VoucherClaimed(address indexed citizen, uint256 indexed id);
    event VoucherDonated(address indexed citizen, address indexed candidate, uint256 indexed id);
    event VoucherSpent(address indexed candidate, address indexed vendor, uint256 indexed id);
    event VoucherRedeemed(address indexed vendor, uint256 indexed id);

    error NotAccreditedCitizen();
    error AlreadyClaimed();
    error NotVendor();
    error InvalidTransfer();
    error MultiRole(address who);

    constructor(
        address authority_,
        AllowList citizens_,
        AllowList candidates_,
        AllowList vendors_,
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {
        authority = authority_;
        citizens = citizens_;
        candidates = candidates_;
        vendors = vendors_;
    }

    /// @notice Accredited citizen claims their one voucher. Owner-signed via the
    /// account in the full system; sponsored. No proof, no nullifier here —
    /// accreditation already happened at account creation.
    function claimVoucher() external {
        if (!citizens.isRegistered(msg.sender)) revert NotAccreditedCitizen();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        hasClaimed[msg.sender] = true;
        _mint(msg.sender, nextId++);
    }

    /// @notice Candidate spends vouchers to a vendor. Hardcodes `from = msg.sender`
    /// so it rejects operator-approved transfers and self-defends against duplicate
    /// ids (the second occurrence finds the owner already changed).
    function batchTransfer(address to, uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            transferFrom(msg.sender, to, ids[i]);
        }
    }

    /// @notice Vendor redeems (burns) vouchers it strictly owns. Cannot reuse the
    /// public transferFrom/safeTransferFrom since OZ rejects `to == address(0)`
    /// there.
    function redeem(uint256[] calldata ids) external {
        if (!vendors.isRegistered(msg.sender)) revert NotVendor();
        for (uint256 i = 0; i < ids.length; i++) {
            address owner = _ownerOf(ids[i]);
            if (owner != msg.sender) {
                revert ERC721IncorrectOwner(msg.sender, ids[i], owner);
            }
            _burn(ids[i]);
        }
    }

    /// @dev Reverts if `who` is registered in more than one AllowList; an address
    /// must have exactly one role for the state machine below to apply unambiguously.
    function _roleOf(address who) internal view returns (Role) {
        bool isCitizen = citizens.isRegistered(who);
        bool isCandidate = candidates.isRegistered(who);
        bool isVendor = vendors.isRegistered(who);

        uint256 count = (isCitizen ? 1 : 0) + (isCandidate ? 1 : 0) + (isVendor ? 1 : 0);
        if (count > 1) revert MultiRole(who);

        if (isCitizen) return Role.Citizen;
        if (isCandidate) return Role.Candidate;
        if (isVendor) return Role.Vendor;
        return Role.None;
    }

    /// @dev The single enforcement point for the transfer-rule state machine
    /// (SPEC §3.5): every other (from,to) role pair reverts. Every mint (claimVoucher),
    /// transfer (donation via transferFrom, spend via batchTransfer), and burn
    /// (redeem) routes through this hook, which is also the single place that emits
    /// the semantic lifecycle events (alongside ERC-721's own Transfer) so the
    /// voucher's path is legible directly from the logs.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        if (from == address(0)) {
            // mint: only 0 -> citizen
            if (_roleOf(to) != Role.Citizen) revert InvalidTransfer();
            address prev = super._update(to, tokenId, auth);
            emit VoucherClaimed(to, tokenId);
            return prev;
        } else if (to == address(0)) {
            // burn: only vendor -> 0
            if (_roleOf(from) != Role.Vendor) revert InvalidTransfer();
            address prev = super._update(to, tokenId, auth);
            emit VoucherRedeemed(from, tokenId);
            return prev;
        } else {
            Role fromRole = _roleOf(from);
            Role toRole = _roleOf(to);
            bool isDonation = fromRole == Role.Citizen && toRole == Role.Candidate;
            bool isSpend = fromRole == Role.Candidate && toRole == Role.Vendor;
            if (!isDonation && !isSpend) revert InvalidTransfer();
            address prev = super._update(to, tokenId, auth);
            if (isDonation) emit VoucherDonated(from, to, tokenId);
            else emit VoucherSpent(from, to, tokenId);
            return prev;
        }
    }
}
