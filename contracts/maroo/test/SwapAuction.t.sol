// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapAuction} from "../src/SwapAuction.sol";

contract SwapAuctionTest is Test {
    SwapAuction auction;
    address admin = makeAddr("admin");
    address escrow = makeAddr("escrow");
    address solverA = makeAddr("solverA");
    address solverB = makeAddr("solverB");
    address alice = makeAddr("alice");

    function setUp() public {
        auction = new SwapAuction(admin, escrow, 1 ether, 10 minutes, 0.1 ether);
        vm.deal(solverA, 10 ether);
        vm.deal(solverB, 10 ether);
    }

    function regBoth() internal {
        vm.prank(solverA);
        auction.register{value: 1 ether}();
        vm.prank(solverB);
        auction.register{value: 1 ether}();
    }

    // ------------------------------------------------------------- registration

    function test_register_and_exit() public {
        vm.prank(solverA);
        auction.register{value: 1 ether}();
        assertTrue(auction.isSolver(solverA));
        assertEq(auction.bonds(solverA), 1 ether);
        uint256 before = solverA.balance;
        vm.prank(solverA);
        auction.exit();
        assertEq(solverA.balance - before, 1 ether);
        assertFalse(auction.isSolver(solverA));
    }

    function test_register_revertsInsufficientBond() public {
        vm.prank(solverA);
        vm.expectRevert(abi.encodeWithSelector(SwapAuction.InsufficientBond.selector, 0.5 ether, 1 ether));
        auction.register{value: 0.5 ether}();
    }

    function test_register_revertsDouble() public {
        vm.prank(solverA);
        auction.register{value: 1 ether}();
        vm.prank(solverA);
        vm.expectRevert(SwapAuction.AlreadyRegistered.selector);
        auction.register{value: 1 ether}();
    }

    function test_unregistered_cannotQuote() public {
        vm.prank(alice);
        auction.notifyLock(0);
        vm.prank(alice); // not a solver
        vm.expectRevert(SwapAuction.NotRegistered.selector);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
    }

    // ----------------------------------------------------------------- auction

    function test_bestQuoteWins() public {
        regBoth();
        auction.notifyLock(0);
        vm.prank(solverA);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
        vm.prank(solverB);
        auction.submitQuote(0, 150, uint64(block.timestamp + 1 days), 50);
        vm.warp(block.timestamp + 10 minutes + 1);
        address w = auction.finalize(0);
        assertEq(w, solverB);
        assertEq(auction.winner(0), solverB);
    }

    function test_quoteBelowMinOutReverts() public {
        regBoth();
        auction.notifyLock(0);
        vm.prank(solverA);
        vm.expectRevert(SwapAuction.QuoteBelowMinOut.selector);
        auction.submitQuote(0, 10, uint64(block.timestamp + 1 days), 50);
    }

    function test_improveOnly_noDowngrade() public {
        regBoth();
        auction.notifyLock(0);
        vm.prank(solverA);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
        vm.prank(solverA);
        vm.expectRevert(SwapAuction.QuoteBelowMinOut.selector);
        auction.submitQuote(0, 90, uint64(block.timestamp + 1 days), 50);
        vm.prank(solverA);
        auction.submitQuote(0, 120, uint64(block.timestamp + 1 days), 50);
        assertEq(auction.quoteCount(0), 1); // still one quote (replaced)
    }

    function test_finalize_revertsWhileOpen() public {
        regBoth();
        auction.notifyLock(0);
        vm.prank(solverA);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
        vm.expectRevert(SwapAuction.AuctionOpen.selector);
        auction.finalize(0);
    }

    function test_finalize_revertsNoQuotes() public {
        auction.notifyLock(0);
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.expectRevert(SwapAuction.NoQuotes.selector);
        auction.finalize(0);
    }

    function test_quotesClosedAfterWindow() public {
        regBoth();
        auction.notifyLock(0);
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(solverA);
        vm.expectRevert(SwapAuction.AuctionClosed.selector);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
    }

    // ----------------------------------------------------------------- default

    function test_reportDefault_slashesToUser() public {
        regBoth();
        auction.notifyLock(0);
        vm.prank(solverA);
        auction.submitQuote(0, 100, uint64(block.timestamp + 1 days), 50);
        vm.warp(block.timestamp + 10 minutes + 1);
        auction.finalize(0);
        uint256 before = alice.balance;
        auction.reportDefault(0, payable(alice));
        assertEq(alice.balance - before, 0.1 ether);
        assertEq(auction.bonds(solverA), 0.9 ether);
        // One-shot: second report reverts.
        vm.expectRevert(SwapAuction.NoQuotes.selector);
        auction.reportDefault(0, payable(alice));
    }

    // ------------------------------------------------------------------- admin

    function test_admin_rotation() public {
        vm.prank(admin);
        auction.proposeAdmin(alice);
        vm.prank(alice);
        auction.acceptAdmin();
        assertEq(auction.admin(), alice);
    }
}
