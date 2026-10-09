/// Local end-to-end test for Move Bridge Swaps: deploys SwapEscrow to an
/// in-process chain and runs lock -> claim -> settle and lock -> refund,
/// asserting the event payloads the solver (swap/src/solver.ts) consumes.
/// Run with: forge test --match-contract SwapLocalE2E
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";

contract SwapLocalE2E is Test {
    SwapEscrow escrow;
    address solver = makeAddr("solver");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    bytes constant APTOS_ALICE = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes32 constant FILL_TX = hex"1111111111111111111111111111111111111111111111111111111111111111";

    function setUp() public {
        escrow = new SwapEscrow(solver, admin, 10 ether, 100 ether, 1 hours);
        vm.deal(alice, 50 ether);
    }

    /// Full happy path: lock emits what solver.ts parses; claim+settle pays solver.
    function test_e2e_swapFill() public {
        vm.recordLogs();
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        assertEq(id, 0);

        // Event shape solver parses: (swapId indexed, user indexed, bytes, uint256, uint256, uint64).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 3); // sig + swapId + user
        assertEq(uint256(logs[0].topics[1]), 0);
        (bytes memory recipient, uint256 amount, uint256 minOut, uint64 deadline) =
            abi.decode(logs[0].data, (bytes, uint256, uint256, uint64));
        assertEq(recipient, APTOS_ALICE);
        assertEq(amount, 1 ether);
        assertEq(minOut, 100);
        assertEq(deadline, block.timestamp + 1 days);

        // Solver fills on Aptos (off-chain), then claims with proof.
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = solver.balance;
        escrow.settle(id); // anyone may settle
        assertEq(solver.balance - before, 1 ether);
        assertEq(escrow.escrowed(), 0);
    }

    /// Refund path: no fill, deadline passes, user recovers in full.
    function test_e2e_swapRefund() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 2 ether}(APTOS_ALICE, 100, 1 days);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        escrow.refund(id);
        assertEq(alice.balance - before, 2 ether);
        assertEq(escrow.escrowed(), 0);
    }

    /// Conservation: N locks in, fills + refunds out, escrow ends at zero.
    function test_e2e_conservation() public {
        vm.prank(alice);
        uint64 a = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        vm.prank(alice);
        uint64 b = escrow.lock{value: 2 ether}(APTOS_ALICE, 100, 1 days);
        assertEq(escrow.escrowed(), 3 ether);
        vm.prank(solver);
        escrow.claim(a, FILL_TX, APTOS_ALICE, 100);
        vm.warp(block.timestamp + 1 hours + 1);
        escrow.settle(a);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        escrow.refund(b);
        assertEq(escrow.escrowed(), 0);
    }
}
