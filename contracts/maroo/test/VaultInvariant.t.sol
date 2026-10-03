// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {OkrwVault} from "../src/OkrwVault.sol";

/// Handler: fuzzes deposit/release/pause/cap sequences against the vault,
/// tracking ghost state for invariant checks.
contract VaultHandler is Test {
    OkrwVault public vault;
    address public relayer;
    address public admin;

    uint256 public ghostDeposited;
    uint256 public ghostReleased;
    uint256 public ghostReleasedToday; // mirrors vault's lazy day-window accounting
    uint256 public ghostDay;
    uint256 public ghostDepositCount;
    uint64 public ghostNextReleaseNonce;
    mapping(bytes32 => bool) public ghostProcessed;

    bytes constant RECIPIENT = hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    constructor(OkrwVault _vault, address _relayer, address _admin) {
        vault = _vault;
        relayer = _relayer;
        admin = _admin;
        ghostDay = vault.currentDay();
    }

    function deposit(uint256 amount, address sender) public {
        amount = bound(amount, 1 wei, 50 ether);
        sender = address(uint160(bound(uint256(uint160(sender)), 1, type(uint160).max)));
        // Exclude the vault itself: a self-deposit would be balance-neutral
        // on-chain but counted in ghost state (false conservation break).
        if (sender == address(vault)) sender = admin;
        vm.deal(sender, amount);
        if (vault.paused()) return; // would revert; skip
        vm.prank(sender);
        try vault.deposit{value: amount}(RECIPIENT) returns (uint64 nonce) {
            ghostDeposited += amount;
            ghostDepositCount += 1;
            assert(nonce == ghostDepositCount - 1); // nonces strictly sequential
        } catch {}
    }

    function release(uint256 amount, address to) public {
        amount = bound(amount, 1 wei, 50 ether);
        if (to == address(0) || to == address(vault)) to = admin;
        uint64 nonce = ghostNextReleaseNonce;
        vm.prank(relayer);
        try vault.release(payable(to), amount, nonce) {
            ghostReleased += amount;
            // Mirror the vault's lazy day-window rollover exactly.
            uint256 day = block.timestamp / 1 days;
            if (day > ghostDay) {
                ghostDay = day;
                ghostReleasedToday = 0;
            }
            ghostReleasedToday += amount;
            ghostNextReleaseNonce = nonce + 1;
            ghostProcessed[keccak256(abi.encode(to, amount, nonce))] = true;
            // Cap discipline at the moment of release: the vault must never
            // let a release push the window total above the then-current cap.
            assert(vault.releasedToday() <= vault.dailyReleaseCap());
        } catch {
            // Expected reverts: cap exceeded, out-of-order (never here),
            // paused, insufficient escrow. State must be unchanged — checked
            // by invariants (nonce not consumed, releasedToday unchanged).
        }
    }

    function releaseWrongNonce(uint64 wrongNonce) public {
        vm.assume(wrongNonce != ghostNextReleaseNonce);
        vm.prank(relayer);
        try vault.release(payable(admin), 1 wei, wrongNonce) {
            // Must never succeed with a wrong nonce.
            assert(false);
        } catch {}
        assert(vault.nextReleaseNonce() == ghostNextReleaseNonce);
    }

    function pauseUnpause(bool doPause, address caller) public {
        // Only admin can pause; anyone else must revert.
        vm.prank(caller);
        if (caller == admin) {
            if (doPause) vault.pause();
            else vault.unpause();
        } else {
            try vault.pause() {
                assert(false); // non-admin pause must never succeed
            } catch {}
        }
    }

    function setCap(uint256 cap, address caller) public {
        vm.prank(caller);
        if (caller == admin) {
            vault.setDailyReleaseCap(cap);
        } else {
            try vault.setDailyReleaseCap(cap) {
                assert(false);
            } catch {}
        }
    }

    function warpDay(uint8 days_) public {
        vm.warp(block.timestamp + uint256(days_) * 1 days + 1);
        // NOTE: ghost window is NOT reset here — the vault rolls its window
        // lazily on the next release, and ghost mirrors that in release().
        // invariant_windowMirror therefore holds at every check point.
    }
}

/// Invariant suite: conservation + nonce integrity + cap discipline hold
/// across arbitrary interleavings of deposits, releases, pauses, cap
/// changes, and day-boundary warps.
contract VaultInvariant is StdInvariant, Test {
    OkrwVault vault;
    VaultHandler handler;
    address relayer = makeAddr("relayer");
    address admin = makeAddr("admin");

    function setUp() public {
        vault = new OkrwVault(relayer, admin, 100 ether);
        handler = new VaultHandler(vault, relayer, admin);
        targetContract(address(handler));
    }

    /// Conservation: escrowed == deposited - released, always.
    function invariant_conservation() public view {
        assertEq(vault.escrowed(), handler.ghostDeposited() - handler.ghostReleased());
    }

    /// Deposit nonces track the deposit count exactly.
    function invariant_depositNonceIntegrity() public view {
        assertEq(vault.nextDepositNonce(), handler.ghostDepositCount());
    }

    /// Release nonce on-chain matches ghost (no nonce ever skipped/consumed
    /// by a failed release).
    function invariant_releaseNonceIntegrity() public view {
        assertEq(vault.nextReleaseNonce(), handler.ghostNextReleaseNonce());
    }

    /// Daily-window mirror: ghost day accounting matches the vault exactly
    /// (lazy rollover on release). Replaces the naive releasedToday<=cap
    /// check, which is legitimately violated right after an admin LOWERS the
    /// cap below today's already-released total.
    function invariant_windowMirror() public view {
        assertEq(vault.currentDay(), handler.ghostDay());
        assertEq(vault.releasedToday(), handler.ghostReleasedToday());
    }
}
