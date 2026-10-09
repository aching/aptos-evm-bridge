// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {SwapAuction} from "../src/SwapAuction.sol";
import {AptosLightClient} from "../src/AptosLightClient.sol";

/// Deploy SwapEscrow + SwapAuction + AptosLightClient (local Anvil demo / testnet).
/// Env: DEPLOYER_PRIVATE_KEY (forge --private-key also works), ADMIN (default: deployer).
contract DeploySwap is Script {
    function run()
        external
        returns (SwapEscrow escrow, SwapAuction auction, AptosLightClient lc)
    {
        address admin = vm.envOr("ADMIN", msg.sender);
        vm.startBroadcast();
        escrow = new SwapEscrow(admin, admin, 10 ether, 100 ether, 1 hours);
        auction = new SwapAuction(admin, address(escrow), 1 ether, 10 minutes, 0.1 ether);
        lc = new AptosLightClient(admin);
        escrow.setLightClient(address(lc));
        escrow.setSwapAuction(address(auction));
        vm.stopBroadcast();
    }
}
