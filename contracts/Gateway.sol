// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function claimBehalf(address user) external;
}

contract Gateway {

    function claimAll(address[] calldata vaults) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            IVault(vault).claimBehalf(msg.sender);
        }
    }
} 