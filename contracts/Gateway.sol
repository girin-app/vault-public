// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IVault {
    function claimBehalf(address user) external;
}

contract Gateway is Ownable {

    constructor(address _owner) Ownable(_owner) {}
    function claimAll(address user, address[] calldata vaults) external {
        require(user != address(0), "Invalid user");
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            IVault(vault).claimBehalf(user);
        }
    }
} 