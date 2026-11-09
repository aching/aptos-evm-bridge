// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {SwapAuction} from "../src/SwapAuction.sol";

/// Maroo testnet deploy: escrow + auction only. AptosLightClient (58KB) exceeds
/// the EIP-170 24KB limit forge enforces; the proven-fill path stays dormant
/// (claimProven reverts without an LC) while solver-attested claim/settle —
/// the path the daemon uses — works fully.
contract DeploySwapNoLC is Script {
    function run()
        external
        returns (SwapEscrow escrow, SwapAuction auction)
    {
        address admin = vm.envOr("ADMIN", msg.sender);
        vm.startBroadcast();
        escrow = new SwapEscrow(admin, admin, 10 ether, 100 ether, 1 hours);
        auction = new SwapAuction(admin, address(escrow), 1 ether, 10 minutes, 0.1 ether);
        escrow.setSwapAuction(address(auction));
        vm.stopBroadcast();
    }
}
