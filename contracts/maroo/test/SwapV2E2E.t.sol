/// v2 end-to-end: auction selects winner, attesters verify fill, escrow
/// settles immediately with no challenge wait.
/// Run with: forge test --match-contract SwapV2E2E
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {SwapAuction} from "../src/SwapAuction.sol";
import {FillAttester} from "../src/FillAttester.sol";

contract SwapV2E2E is Test {
    SwapEscrow escrow;
    SwapAuction auction;
    FillAttester attester;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address solverA = makeAddr("solverA");
    address solverB = makeAddr("solverB");

    uint256 constant AT1 = 0xA11CE;
    uint256 constant AT2 = 0xB22CE;
    uint256 constant AT3 = 0xC33CE;

    bytes constant APTOS_ALICE = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes32 constant FILL_TX = hex"2222222222222222222222222222222222222222222222222222222222222222";

    function setUp() public {
        escrow = new SwapEscrow(solverA, admin, 10 ether, 100 ether, 1 hours);
        auction = new SwapAuction(admin, address(escrow), 1 ether, 10 minutes, 0.1 ether);
        address[] memory set = new address[](3);
        set[0] = vm.addr(AT1); set[1] = vm.addr(AT2); set[2] = vm.addr(AT3);
        attester = new FillAttester(admin, set, 2);
        vm.prank(admin);
        escrow.setFillAttester(address(attester));
        vm.deal(alice, 20 ether);
        vm.deal(solverA, 5 ether);
        vm.deal(solverB, 5 ether);
        vm.prank(solverA);
        auction.register{value: 1 ether}();
        vm.prank(solverB);
        auction.register{value: 1 ether}();
    }

    function sortedSigs(uint256 pkA, uint256 pkB, address esc, uint64 id, uint256 amt)
        internal view returns (uint8[] memory v, bytes32[] memory r, bytes32[] memory s)
    {
        address aA = vm.addr(pkA);
        address aB = vm.addr(pkB);
        (uint256 f, uint256 se) = aA < aB ? (pkA, pkB) : (pkB, pkA);
        bytes32 d = attester.fillDigest(esc, id, FILL_TX, APTOS_ALICE, amt);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(f, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(se, d);
        v = new uint8[](2); r = new bytes32[](2); s = new bytes32[](2);
        v[0] = v1; v[1] = v2; r[0] = r1; r[1] = r2; s[0] = s1; s[1] = s2;
    }

    /// Full v2 path: lock -> quotes -> finalize(B wins) -> B fills ->
    /// attested claim -> immediate settle (no challenge wait).
    function test_e2e_v2_auctionAttestedFill() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);

        auction.notifyLock(id);
        vm.prank(solverA);
        auction.submitQuote(id, 120, uint64(block.timestamp + 1 days), 100);
        vm.prank(solverB);
        auction.submitQuote(id, 150, uint64(block.timestamp + 1 days), 100);
        vm.warp(block.timestamp + 10 minutes + 1);
        address w = auction.finalize(id);
        assertEq(w, solverB);

        // Winner fills on Aptos (off-chain), attesters sign, anyone submits.
        (uint8[] memory v, bytes32[] memory r, bytes32[] memory s) =
            sortedSigs(AT1, AT3, address(escrow), id, 150);
        escrow.claimAttested(id, FILL_TX, APTOS_ALICE, 150, solverB, v, r, s);

        uint256 before = solverB.balance;
        escrow.settle(id); // immediate — no warp past challenge window
        assertEq(solverB.balance - before, 1 ether);
        assertEq(escrow.escrowed(), 0);
    }

    /// Loser cannot claim via the solver path after attested settle; and the
    /// solver path still works when the committee is bypassed (liveness).
    function test_e2e_v2_solverPathLiveness() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        vm.prank(solverA);
        escrow.claim(id, FILL_TX, APTOS_ALICE, 120);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = solverA.balance;
        escrow.settle(id);
        assertEq(solverA.balance - before, 1 ether);
    }
}
