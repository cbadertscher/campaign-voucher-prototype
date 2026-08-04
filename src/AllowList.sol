// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Admin-gated membership registry. One instance per role (citizens,
/// candidates, vendors); the admin address distinguishes who controls each list
/// (the CitizenFactory for citizens, the authority for candidates/vendors).
contract AllowList {
    address public admin;
    mapping(address => bool) public isRegistered;

    event Registered(address indexed who);
    event Revoked(address indexed who);

    error NotAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address admin_) {
        admin = admin_;
    }

    function register(address who) external onlyAdmin {
        isRegistered[who] = true;
        emit Registered(who);
    }

    function revoke(address who) external onlyAdmin {
        isRegistered[who] = false;
        emit Revoked(who);
    }
}
