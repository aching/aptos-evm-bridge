// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {OkrwVault} from "../src/OkrwVault.sol";

/// Deploy OkrwVault to Maroo testnet.
/// Env: MAROO_RELAYER_ADDRESS, MAROO_ADMIN_ADDRESS (default: deployer), DAILY_RELEASE_CAP_WEI
contract DeployVault is Script {
    function run() external returns (OkrwVault vault) {
        address relayer = vm.envAddress("MAROO_RELAYER_ADDRESS");
        address admin = vm.envOr("MAROO_ADMIN_ADDRESS", msg.sender);
        uint256 cap = vm.envOr("DAILY_RELEASE_CAP_WEI", uint256(1000 ether));
        vm.startBroadcast();
        vault = new OkrwVault(relayer, admin, cap);
        vm.stopBroadcast();
    }
}
