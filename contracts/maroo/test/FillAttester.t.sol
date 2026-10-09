// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FillAttester} from "../src/FillAttester.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";

contract FillAttesterTest is Test {
    FillAttester attester;
    address admin = makeAddr("admin");

    uint256 constant A1_PK = 0xA11CE;
    uint256 constant A2_PK = 0xB22CE;
    uint256 constant A3_PK = 0xC33CE;
    address a1; address a2; address a3;

    bytes constant RECIPIENT = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes32 constant FILL_TX = hex"1111111111111111111111111111111111111111111111111111111111111111";

    function setUp() public {
        a1 = vm.addr(A1_PK);
        a2 = vm.addr(A2_PK);
        a3 = vm.addr(A3_PK);
        address[] memory set = new address[](3);
        set[0] = a1; set[1] = a2; set[2] = a3;
        attester = new FillAttester(admin, set, 2);
    }

    function signFill(uint256 pk, address escrow, uint64 swapId, uint256 amount)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = attester.fillDigest(escrow, swapId, FILL_TX, RECIPIENT, amount);
        (v, r, s) = vm.sign(pk, digest);
    }

    /// @dev verifyAndConsume requires sigs sorted by ascending signer.
    function sigArrays(uint256 pkA, uint256 pkB, address escrow, uint64 swapId, uint256 amount)
        internal view returns (uint8[] memory v, bytes32[] memory r, bytes32[] memory s)
    {
        address addrA = vm.addr(pkA);
        address addrB = vm.addr(pkB);
        (uint256 first, uint256 second) = addrA < addrB ? (pkA, pkB) : (pkB, pkA);
        (uint8 v1, bytes32 r1, bytes32 s1) = signFill(first, escrow, swapId, amount);
        (uint8 v2, bytes32 r2, bytes32 s2) = signFill(second, escrow, swapId, amount);
        v = new uint8[](2); r = new bytes32[](2); s = new bytes32[](2);
        v[0] = v1; v[1] = v2; r[0] = r1; r[1] = r2; s[0] = s1; s[1] = s2;
    }

    // ---------------------------------------------------------------- verify

    function test_verifyAndConsume_2of3() public {
        (uint8[] memory v, bytes32[] memory r, bytes32[] memory s) =
            sigArrays(A1_PK, A2_PK, address(this), 0, 100);
        bytes32 digest = attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
        assertTrue(attester.consumed(digest));
    }

    function test_replay_reverts() public {
        (uint8[] memory v, bytes32[] memory r, bytes32[] memory s) =
            sigArrays(A1_PK, A2_PK, address(this), 0, 100);
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(FillAttester.AlreadyConsumed.selector, attester.fillDigest(address(this), 0, FILL_TX, RECIPIENT, 100)));
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
    }

    function test_threshold_notMet_reverts() public {
        (uint8 v1, bytes32 r1, bytes32 s1) = signFill(A1_PK, address(this), 0, 100);
        uint8[] memory v = new uint8[](1); bytes32[] memory r = new bytes32[](1); bytes32[] memory s = new bytes32[](1);
        v[0] = v1; r[0] = r1; s[0] = s1;
        vm.expectRevert(abi.encodeWithSelector(FillAttester.InsufficientSignatures.selector, 1, 2));
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
    }

    function test_duplicateSigner_reverts() public {
        // Same signer twice: sorted-order check fails (signer <= prev).
        (uint8 v1, bytes32 r1, bytes32 s1) = signFill(A1_PK, address(this), 0, 100);
        uint8[] memory v = new uint8[](2); bytes32[] memory r = new bytes32[](2); bytes32[] memory s = new bytes32[](2);
        v[0] = v1; v[1] = v1; r[0] = r1; r[1] = r1; s[0] = s1; s[1] = s1;
        vm.expectRevert(FillAttester.BadSignature.selector);
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
    }

    function test_unsortedSignatures_revert() public {
        // Valid sigs in descending signer order must fail the sort check.
        address addr1 = vm.addr(A1_PK);
        address addr2 = vm.addr(A2_PK);
        (uint256 hi, uint256 lo) = addr1 > addr2 ? (A1_PK, A2_PK) : (A2_PK, A1_PK);
        (uint8 vh, bytes32 rh, bytes32 sh) = signFill(hi, address(this), 0, 100);
        (uint8 vl, bytes32 rl, bytes32 sl) = signFill(lo, address(this), 0, 100);
        uint8[] memory v = new uint8[](2); bytes32[] memory r = new bytes32[](2); bytes32[] memory s = new bytes32[](2);
        v[0] = vh; v[1] = vl; r[0] = rh; r[1] = rl; s[0] = sh; s[1] = sl;
        vm.expectRevert(FillAttester.BadSignature.selector);
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
    }

    function test_nonAttester_reverts() public {
        // 0xDEAD + A2: sorted helper can't mix unknown keys, build manually.
        (uint8 vd, bytes32 rd, bytes32 sd) = signFill(0xDEAD, address(this), 0, 100);
        (uint8 v2, bytes32 r2, bytes32 s2) = signFill(A2_PK, address(this), 0, 100);
        address dead = vm.addr(0xDEAD);
        uint8[] memory v = new uint8[](2); bytes32[] memory r = new bytes32[](2); bytes32[] memory s = new bytes32[](2);
        if (dead < a2) { v[0]=vd; v[1]=v2; r[0]=rd; r[1]=r2; s[0]=sd; s[1]=s2; }
        else { v[0]=v2; v[1]=vd; r[0]=r2; r[1]=rd; s[0]=s2; s[1]=sd; }
        vm.expectRevert(FillAttester.BadSignature.selector);
        attester.verifyAndConsume(address(this), 0, FILL_TX, RECIPIENT, 100, v, r, s);
    }

    function test_domainSeparator_bindsDeploymentChain() public {
        // DOMAIN_SEPARATOR is immutable: baked at construction with the
        // deploy-time chainid. A redeploy on another chain gets a different
        // separator, so fills can't migrate across chains/deployments.
        bytes32 sep = attester.DOMAIN_SEPARATOR();
        vm.chainId(99999);
        address[] memory set = new address[](1);
        set[0] = a1;
        FillAttester other = new FillAttester(admin, set, 1);
        assertTrue(sep != other.DOMAIN_SEPARATOR());
    }

    // ------------------------------------------------------------------- admin

    function test_removeAttester_floorEnforced() public {
        // 3 members, threshold 2: removing one is fine, removing two breaks floor.
        vm.prank(admin);
        attester.removeAttester(a3);
        assertEq(attester.attesterCount(), 2);
        vm.prank(admin);
        vm.expectRevert(FillAttester.ThresholdExceedsSet.selector);
        attester.removeAttester(a2);
    }

    function test_setThreshold_bounds() public {
        vm.prank(admin);
        vm.expectRevert(FillAttester.BadThreshold.selector);
        attester.setThreshold(4);
        vm.prank(admin);
        vm.expectRevert(FillAttester.BadThreshold.selector);
        attester.setThreshold(0);
        vm.prank(admin);
        attester.setThreshold(3);
        assertEq(attester.threshold(), 3);
    }

    // ------------------------------------------------------- escrow integration

    function test_escrow_claimAttested_settlesImmediately() public {
        SwapEscrow escrow = new SwapEscrow(makeAddr("solver"), admin, 10 ether, 100 ether, 1 hours);
        vm.prank(admin);
        escrow.setFillAttester(address(attester));
        address alice = makeAddr("alice");
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(RECIPIENT, 100, 1 days);
        (uint8[] memory v, bytes32[] memory r, bytes32[] memory s) =
            sigArrays(A1_PK, A2_PK, address(escrow), id, 150);
        address winner = makeAddr("winner");
        // Anyone may submit; ETH goes to the winner.
        escrow.claimAttested(id, FILL_TX, RECIPIENT, 150, winner, v, r, s);
        uint256 before = winner.balance;
        escrow.settle(id); // no challenge wait
        assertEq(winner.balance - before, 1 ether);
    }

    function test_escrow_claimAttested_revertsWithoutAttester() public {
        SwapEscrow escrow = new SwapEscrow(makeAddr("solver"), admin, 10 ether, 100 ether, 1 hours);
        // fillAttester never set (zero).
        address alice = makeAddr("alice");
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        uint64 id = escrow.lock{value: 1 ether}(RECIPIENT, 100, 1 days);
        uint8[] memory v = new uint8[](0); bytes32[] memory r = new bytes32[](0); bytes32[] memory s = new bytes32[](0);
        vm.expectRevert(SwapEscrow.NotLocked.selector);
        escrow.claimAttested(id, FILL_TX, RECIPIENT, 150, makeAddr("winner"), v, r, s);
    }
}
