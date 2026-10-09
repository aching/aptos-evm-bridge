// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";

contract SwapEscrowTest is Test {
    SwapEscrow escrow;
    address admin = makeAddr("admin");
    address solver = makeAddr("solver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes constant APTOS_ALICE = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes32 constant FILL_TX = keccak256("aptos-fill-tx");

    function setUp() public {
        escrow = new SwapEscrow(solver, admin, 10 ether, 100 ether, 1 hours);
        vm.deal(alice, 50 ether);
        vm.deal(solver, 10 ether);
    }

    function lockAlice(uint256 amount, uint256 minOut) internal returns (uint64) {
        vm.prank(alice);
        return escrow.lock{value: amount}(APTOS_ALICE, minOut, 1 days);
    }

    // ------------------------------------------------------------------ lock

    function test_lock_emitsAndEscrows() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        assertEq(id, 0);
        assertEq(escrow.escrowed(), 1 ether);
        (address user, , uint256 amount, uint256 minOut, , , , , ,) = escrow.swaps(0);
        assertEq(user, alice);
        assertEq(amount, 1 ether);
        assertEq(minOut, 100);
    }

    function test_lock_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(SwapEscrow.ZeroAmount.selector);
        escrow.lock{value: 0}(APTOS_ALICE, 100, 1 days);
    }

    function test_lock_revertsOverMaxSwap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.DailyCapExceeded.selector, 11 ether, 10 ether));
        escrow.lock{value: 11 ether}(APTOS_ALICE, 100, 1 days);
    }

    function test_lock_revertsBadRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.BadRecipientLength.selector, 3));
        escrow.lock{value: 1 ether}(hex"aabbcc", 100, 1 days);
    }

    function test_lock_revertsWhenPaused() public {
        vm.prank(admin);
        escrow.pause();
        vm.prank(alice);
        vm.expectRevert(SwapEscrow.IsPaused.selector);
        escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
    }

    function test_directTransferReverts() public {
        vm.prank(alice);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------ claim/settle

    function test_claimSettle_happyPath() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        uint256 before = solver.balance;
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob); // anyone can settle
        escrow.settle(id);
        assertEq(solver.balance - before, 1 ether);
        assertEq(escrow.escrowed(), 0);
    }

    function test_claim_revertsNotSolver() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.NotSolver.selector, bob));
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
    }

    function test_claim_revertsMinOutNotMet() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.MinOutNotMet.selector, 100, 50));
        escrow.claim(id, FILL_TX, APTOS_ALICE, 50);
    }

    function test_claim_revertsRecipientMismatch() public {
        uint64 id = lockAlice(1 ether, 100);
        bytes memory wrong = hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        vm.prank(solver);
        vm.expectRevert(SwapEscrow.FillRecipientMismatch.selector);
        escrow.claim(id, FILL_TX, wrong, 150);
    }

    function test_settle_revertsBeforeChallengeWindow() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.NotClaimableYet.selector, block.timestamp + 1 hours));
        escrow.settle(id);
    }

    function test_challenge_cancelsClaim() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.prank(bob); // anyone can challenge in v1
        escrow.challenge(id);
        // Claim cleared: settle now reverts, user can refund after deadline.
        vm.expectRevert(SwapEscrow.NotLocked.selector);
        escrow.settle(id);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        escrow.refund(id);
        assertEq(alice.balance - before, 1 ether);
    }

    function test_noDoubleClaimOrSettle() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.prank(solver);
        vm.expectRevert(SwapEscrow.AlreadyClaimed.selector);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.warp(block.timestamp + 1 hours + 1);
        escrow.settle(id);
        vm.expectRevert(SwapEscrow.AlreadySettled.selector);
        escrow.settle(id);
    }

    // ----------------------------------------------------------------- refund

    function test_refund_afterDeadline() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        escrow.refund(id);
        assertEq(alice.balance - before, 1 ether);
        assertEq(escrow.escrowed(), 0);
    }

    function test_refund_revertsBeforeDeadline() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.DeadlineNotPassed.selector, block.timestamp + 1 days));
        escrow.refund(id);
    }

    function test_refund_revertsNotUser() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.NotUser.selector, bob));
        escrow.refund(id);
    }

    function test_refund_worksWhenPaused() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(admin);
        escrow.pause();
        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        escrow.refund(id);
        assertEq(alice.balance - before, 1 ether);
    }

    function test_refund_revertsAfterSettle() public {
        uint64 id = lockAlice(1 ether, 100);
        vm.prank(solver);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 150);
        vm.warp(block.timestamp + 1 hours + 1);
        escrow.settle(id);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(SwapEscrow.AlreadySettled.selector);
        escrow.refund(id);
    }

    // ------------------------------------------------------------------- admin

    function test_admin_twoStepRotation() public {
        vm.prank(admin);
        escrow.proposeAdmin(bob);
        vm.prank(bob);
        escrow.acceptAdmin();
        assertEq(escrow.admin(), bob);
    }

    function test_dailyClaimCap_enforced() public {
        // Cap 100 ether total; lock 60 + 60, claim both, second settle busts cap.
        SwapEscrow tight = new SwapEscrow(solver, admin, 100 ether, 100 ether, 0);
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        uint64 a = tight.lock{value: 60 ether}(APTOS_ALICE, 1, 1 days);
        vm.prank(alice);
        uint64 b = tight.lock{value: 60 ether}(APTOS_ALICE, 1, 1 days);
        vm.prank(solver);
        tight.claim(a, FILL_TX, APTOS_ALICE, 1);
        vm.prank(solver);
        tight.claim(b, FILL_TX, APTOS_ALICE, 1);
        tight.settle(a);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.DailyCapExceeded.selector, 60 ether, 40 ether));
        tight.settle(b);
    }
}
