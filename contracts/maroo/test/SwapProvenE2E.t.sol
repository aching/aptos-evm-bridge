/// Proven-fill end-to-end: auction selects winner, light client verifies the
/// Aptos QC + fill inclusion, escrow settles trustlessly with no challenge
/// wait and no committee.
/// Run with: forge test --match-contract SwapProvenE2E
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {SwapAuction} from "../src/SwapAuction.sol";
import {AptosLightClient} from "../src/AptosLightClient.sol";

contract SwapProvenE2E is Test {
    SwapEscrow escrow;
    SwapAuction auction;
    AptosLightClient lc;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address solverA = makeAddr("solverA");
    address solverB = makeAddr("solverB");

    // Fill recipient: 32 bytes of 0xaa (matches the oracle leaf preimage:
    // leaf = SHA3("APTOS::TransactionInfo" || LE64(0) || 0xaa*32 || LE64(1000000))).
    bytes constant APTOS_ALICE = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    // ---- e2e QC vectors (/tmp/e2e-qc.json): epoch-58 QC, signers [0..4],
    // accumulator root covering the fill leaf (swapId 0, 0xaa*32, 1000000).
    // Built by: node swap/src/lc-oracle.mjs (committee) + e2e-fill QC script
    // (see research/swap-plan-2026-10-07.md §9 for regen commands).
    function _e2eBcs() internal pure returns (bytes memory) {
        return hex"3a000000000000003279060000000000942b85fcb6352fde710118ff6bc38a5b00b6201bd45ed246262cfcb774d08a34b098d99b68e8de12fb60d62c31f50c52918d6badcf3f52e29e935f0f07e89654f883060000000000866761004e5d060000de6e8ba35fdd22c10cb70631065b3effe305ed4325e1a0dac96dc5b24ef5075a";
    }

    function _e2eSig() internal pure returns (bytes memory) {
        return hex"875261472ef47be4aa96baeac9893d10f9117dd396942ca3a8ef7a44d65f8448c83d0249411214497818e26abc25fdfc035a04a1c552ae0fa419edf6b47015de36db1bacfad0cd3e924dc8b7d58a657f9fa5baa7f57d19a0ba395afc9796121f";
    }

    bytes32 constant FILL_LEAF = hex"4bbc8b1ce34ad12463d6098cb21458a74c9ccafe70713faf70e8cc50103dde74";
    bytes32 constant FILL_ROOT = hex"b098d99b68e8de12fb60d62c31f50c52918d6badcf3f52e29e935f0f07e89654";

    function _fillSibs() internal pure returns (bytes32[] memory s) {
        // via_ir: build via abi.encode (element stores misroute the 3rd
        // word at depth — AptosLightClient inclusion path, DbgS bisection).
        bytes memory enc = abi.encode(
            bytes32(hex"7df9d8e4be294d24f9cafca7a098436b236cd2e000b5038125f05c68b4ca8c1f"),
            bytes32(hex"f6360c925e14e870b6ebf20a33881be054f3373f58dc2410f8115391f8d0f4e5"),
            bytes32(hex"872aae6980fa12b173be21b59105c6cccb4b2eb4d32e3b5a93b70be379c4ddc2")
        );
        s = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 w;
            // solhint-disable-next-line
            assembly {
                w := mload(add(add(enc, 32), mul(i, 32)))
            }
            s[i] = w;
        }
    }

    function setUp() public {
        escrow = new SwapEscrow(solverA, admin, 10 ether, 100 ether, 1 hours);
        auction = new SwapAuction(admin, address(escrow), 1 ether, 10 minutes, 0.1 ether);
        lc = new AptosLightClient(admin);
        // Anchor the oracle committee (7 keys, sk 1..7).
        bytes[] memory pks = new bytes[](7);
        pks[0] = hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
        pks[1] = hex"a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
        pks[2] = hex"89ece308f9d1f0131765212deca99697b112d61f9be9a5f1f3780a51335b3ff981747a0b2ca2179b96d2c0c9024e5224";
        pks[3] = hex"ac9b60d5afcbd5663a8a44b7c5a02f19e9a77ab0a35bd65809bb5c67ec582c897feb04decc694b13e08587f3ff9b5b60";
        pks[4] = hex"b0e7791fb972fe014159aa33a98622da3cdc98ff707965e536d8636b5fcc5ac7a91a8c46e59a00dca575af0f18fb13dc";
        pks[5] = hex"a6e82f6da4520f85c5d27d8f329eccfa05944fd1096b20734c894966d12a9e2a9a9744529d7212d33883113a0cadb909";
        pks[6] = hex"b928f3beb93519eecf0145da903b40a4c97dca00b21f12ac0df3be9116ef2ef27b2ae6bcd4c5bc2d54ef5a70627efcb7";
        uint64[] memory pws = new uint64[](7);
        pws[0] = 2100123443531745;
        pws[1] = 2100123155682121;
        pws[2] = 2100123063113211;
        pws[3] = 2100123155334467;
        pws[4] = 2100118789251558;
        pws[5] = 2100122872964703;
        pws[6] = 2100122871079190;
        vm.prank(admin);
        lc.anchor(58, pks, pws);
        // Wire escrow -> light client + auction.
        vm.prank(admin);
        escrow.setLightClient(address(lc));
        vm.prank(admin);
        escrow.setSwapAuction(address(auction));
        vm.deal(alice, 20 ether);
        vm.deal(solverA, 5 ether);
        vm.deal(solverB, 5 ether);
        vm.prank(solverA);
        auction.register{value: 1 ether}();
        vm.prank(solverB);
        auction.register{value: 1 ether}();
    }

    /// Full proven path: lock -> quotes -> finalize(B wins) -> B fills on
    /// Aptos -> QC submitted -> claimProven -> immediate settle (no wait).
    function test_e2e_provenFill() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        assertEq(id, 0);

        auction.notifyLock(id);
        vm.prank(solverA);
        auction.submitQuote(id, 120, uint64(block.timestamp + 1 days), 100);
        vm.prank(solverB);
        auction.submitQuote(id, 150, uint64(block.timestamp + 1 days), 100);
        vm.warp(block.timestamp + 10 minutes + 1);
        assertEq(auction.finalize(id), solverB);

        // QC binds the fill root; latestRoot becomes the fill root.
        lc.submitQC(_e2eBcs(), hex"f8", _e2eSig());
        assertEq(lc.latestRoot(), FILL_ROOT);
        assertEq(lc.latestVersion(), 427000);

        // Proven claim by the auction winner settles immediately.
        escrow.claimProven(id, FILL_LEAF, 0, _fillSibs(), solverB);
        uint256 before = solverB.balance;
        escrow.settle(id); // immediate — no warp past challenge window
        assertEq(solverB.balance - before, 1 ether);
        assertEq(escrow.escrowed(), 0);
    }

    /// Non-winner cannot take the proven payout when the auction ran.
    function test_e2e_provenFill_revertsWrongWinner() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        auction.notifyLock(id);
        vm.prank(solverA);
        auction.submitQuote(id, 120, uint64(block.timestamp + 1 days), 100);
        vm.prank(solverB);
        auction.submitQuote(id, 150, uint64(block.timestamp + 1 days), 100);
        vm.warp(block.timestamp + 10 minutes + 1);
        assertEq(auction.finalize(id), solverB);

        lc.submitQC(_e2eBcs(), hex"f8", _e2eSig());
        vm.expectRevert();
        escrow.claimProven(id, FILL_LEAF, 0, _fillSibs(), solverA);
    }

    /// Without an auction (no winner set), the proof alone settles to the
    /// named solver — permissionless settlement.
    function test_e2e_provenFill_noAuction() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        lc.submitQC(_e2eBcs(), hex"f8", _e2eSig());
        escrow.claimProven(id, FILL_LEAF, 0, _fillSibs(), solverA);
        uint256 before = solverA.balance;
        escrow.settle(id);
        assertEq(solverA.balance - before, 1 ether);
    }

    /// Tampered proof (wrong leaf) cannot settle.
    function test_e2e_provenFill_revertsWrongLeaf() public {
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        lc.submitQC(_e2eBcs(), hex"f8", _e2eSig());
        vm.expectRevert();
        escrow.claimProven(id, bytes32(uint256(1)), 0, _fillSibs(), solverA);
    }

    /// Proven path disabled (no light client set) reverts.
    function test_e2e_provenFill_revertsNoLC() public {
        vm.prank(admin);
        escrow.setLightClient(address(0));
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(APTOS_ALICE, 100, 1 days);
        vm.expectRevert();
        escrow.claimProven(id, FILL_LEAF, 0, _fillSibs(), solverA);
    }
}
