/// Local end-to-end test: deploys OkrwVault to an in-process chain,
/// performs deposit -> release, and asserts event payloads match what the
/// TypeScript relayer parses (recipient bytes, amount, nonce ordering).
/// Run with: forge test --match-contract LocalE2E
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {OkrwVault} from "../src/OkrwVault.sol";

contract LocalE2E is Test {
    OkrwVault vault;
    address relayer = makeAddr("relayer");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    // Aptos recipient: 32 raw bytes (BCS address form the relayer forwards).
    bytes constant APTOS_ALICE = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    function setUp() public {
        vault = new OkrwVault(relayer, admin, 100 ether);
        vm.deal(alice, 50 ether);
    }

    /// Full forward leg: deposit emits exactly what forward.ts consumes.
    function test_e2e_forwardLeg() public {
        vm.recordLogs();
        vm.prank(alice);
        uint64 nonce = vault.deposit{value: 5 ether}(APTOS_ALICE);
        assertEq(nonce, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        // topics[0] = event sig, topics[1] = marooSender (indexed)
        assertEq(logs[0].topics.length, 2);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        // data = (bytes aptosRecipient, uint256 amount, uint64 nonce)
        (bytes memory recipient, uint256 amount, uint64 n) =
            abi.decode(logs[0].data, (bytes, uint256, uint64));
        assertEq(recipient, APTOS_ALICE);
        assertEq(recipient.length, 32);
        assertEq(amount, 5 ether);
        assertEq(n, 0);
        assertEq(vault.escrowed(), 5 ether);
    }

    /// Full back leg: relayer releases after Aptos burn; escrow returns to zero.
    function test_e2e_backLeg() public {
        vm.prank(alice);
        vault.deposit{value: 5 ether}(APTOS_ALICE);

        uint256 before = alice.balance;
        vm.prank(relayer);
        vault.release(payable(alice), 5 ether, 0);
        assertEq(alice.balance - before, 5 ether);
        assertEq(vault.escrowed(), 0);
        assertEq(vault.nextReleaseNonce(), 1);
    }

    /// Multi-deposit nonce sequencing (relayer replay protection relies on it).
    function test_e2e_nonceSequence() public {
        vm.startPrank(alice);
        assertEq(vault.deposit{value: 1 ether}(APTOS_ALICE), 0);
        assertEq(vault.deposit{value: 1 ether}(APTOS_ALICE), 1);
        assertEq(vault.deposit{value: 1 ether}(APTOS_ALICE), 2);
        vm.stopPrank();
        assertEq(vault.nextDepositNonce(), 3);
    }
}

/// Malicious recipient: tries to reenter `release` when receiving OKRW.
contract ReentrantRecipient {
    OkrwVault public vault;
    uint256 public reentries;

    constructor(OkrwVault _vault) {
        vault = _vault;
    }

    receive() external payable {
        reentries++;
        // Attempt reentry with the next nonce — must revert (mutex), and
        // in any case `onlyRelayer` blocks us since we are not the relayer.
        try vault.release(payable(address(this)), 1 ether, 999) {} catch {}
    }
}

contract ReentrancyTest is Test {
    function test_release_survivesReentrantRecipient() public {
        address relayer = makeAddr("relayer");
        address admin = makeAddr("admin");
        OkrwVault vault = new OkrwVault(relayer, admin, 100 ether);
        ReentrantRecipient attacker = new ReentrantRecipient(vault);

        address alice = makeAddr("alice");
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vault.deposit{value: 5 ether}(new bytes(32));

        vm.prank(relayer);
        vault.release(payable(address(attacker)), 2 ether, 0);
        // Funds delivered exactly once; the reentry attempt failed.
        assertEq(address(attacker).balance, 2 ether);
        assertEq(vault.nextReleaseNonce(), 1);
        assertEq(uint256(vault.releasedToday()), 2 ether);
    }
}
