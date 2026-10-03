// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OkrwVault} from "../src/OkrwVault.sol";

contract OkrwVaultTest is Test {
    OkrwVault vault;
    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DAILY_CAP = 100 ether;
    bytes constant APTOS_RECIPIENT = hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    function setUp() public {
        vault = new OkrwVault(relayer, admin, DAILY_CAP);
        vm.deal(alice, 1000 ether);
        vm.deal(address(vault), 0); // vault starts empty
    }

    // ------------------------------------------------------------ deposits

    function test_deposit_locksFundsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit OkrwVault.DepositLocked(alice, APTOS_RECIPIENT, 10 ether, 0);
        vm.prank(alice);
        uint64 nonce = vault.deposit{value: 10 ether}(APTOS_RECIPIENT);
        assertEq(nonce, 0);
        assertEq(vault.escrowed(), 10 ether);
        assertEq(vault.nextDepositNonce(), 1);
    }

    function test_deposit_nonceIncrements() public {
        vm.startPrank(alice);
        assertEq(vault.deposit{value: 1 ether}(APTOS_RECIPIENT), 0);
        assertEq(vault.deposit{value: 2 ether}(APTOS_RECIPIENT), 1);
        vm.stopPrank();
        assertEq(vault.escrowed(), 3 ether);
    }

    function test_deposit_revertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(OkrwVault.ZeroAmount.selector);
        vault.deposit(APTOS_RECIPIENT);
    }

    function test_deposit_revertsOnBadRecipientLength() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.BadRecipientLength.selector, 20));
        vault.deposit{value: 1 ether}(new bytes(20));
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert(OkrwVault.IsPaused.selector);
        vault.deposit{value: 1 ether}(APTOS_RECIPIENT);
    }

    function test_directTransfer_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "direct transfers must be rejected");
    }

    // ------------------------------------------------------------ releases

    function _fund(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit{value: amount}(APTOS_RECIPIENT);
    }

    function test_release_happyPath() public {
        _fund(10 ether);
        uint256 before = bob.balance;
        vm.expectEmit(true, false, false, true);
        emit OkrwVault.Released(bob, 4 ether, 0);
        vm.prank(relayer);
        vault.release(payable(bob), 4 ether, 0);
        assertEq(bob.balance - before, 4 ether);
        assertEq(vault.escrowed(), 6 ether);
        assertEq(vault.nextReleaseNonce(), 1);
    }

    function test_release_revertsForNonRelayer() public {
        _fund(10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.NotRelayer.selector, alice));
        vault.release(payable(bob), 1 ether, 0);
    }

    function test_release_revertsOnReplay() public {
        _fund(10 ether);
        vm.startPrank(relayer);
        vault.release(payable(bob), 1 ether, 0);
        // Same (to, amount, nonce) again -> AlreadyProcessed.
        bytes32 id = keccak256(abi.encode(bob, uint256(1 ether), uint64(0)));
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.AlreadyProcessed.selector, id));
        vault.release(payable(bob), 1 ether, 0);
        vm.stopPrank();
    }

    function test_release_revertsOnOutOfOrderNonce() public {
        _fund(10 ether);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.OutOfOrderNonce.selector, 0, 5));
        vault.release(payable(bob), 1 ether, 5);
    }

    function test_release_enforcesDailyCap() public {
        _fund(200 ether);
        vm.startPrank(relayer);
        vault.release(payable(bob), 60 ether, 0);
        vault.release(payable(bob), 40 ether, 1);
        // 100/100 used; next release exceeds cap.
        vm.expectRevert(
            abi.encodeWithSelector(OkrwVault.DailyCapExceeded.selector, 1 ether, 0)
        );
        vault.release(payable(bob), 1 ether, 2);
        vm.stopPrank();
    }

    function test_release_revertsWhenPaused() public {
        _fund(10 ether);
        vm.prank(admin);
        vault.pause();
        vm.prank(relayer);
        vm.expectRevert(OkrwVault.IsPaused.selector);
        vault.release(payable(bob), 1 ether, 0);
    }

    // ----------------------------------------------------------------- admin

    function test_admin_canRotateRelayerAndCap() public {
        vm.prank(admin);
        vault.setRelayer(bob);
        assertEq(vault.relayer(), bob);
        vm.prank(admin);
        vault.setDailyReleaseCap(7 ether);
        assertEq(vault.dailyReleaseCap(), 7 ether);
    }

    function test_nonAdmin_cannotPause() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.NotAdmin.selector, alice));
        vault.pause();
    }

    function test_admin_twoStepTransfer() public {
        // Propose alone changes nothing.
        vm.prank(admin);
        vault.proposeAdmin(bob);
        assertEq(vault.admin(), admin);
        assertEq(vault.pendingAdmin(), bob);
        // Wrong claimant cannot seize admin.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.NotPendingAdmin.selector, alice));
        vault.acceptAdmin();
        // Pending admin completes the handover.
        vm.prank(bob);
        vault.acceptAdmin();
        assertEq(vault.admin(), bob);
        assertEq(vault.pendingAdmin(), address(0));
        // Old admin locked out, new admin works.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OkrwVault.NotAdmin.selector, admin));
        vault.pause();
        vm.prank(bob);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_proposeAdmin_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(OkrwVault.ZeroAddress.selector);
        vault.proposeAdmin(address(0));
    }
}
