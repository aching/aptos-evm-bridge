// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Sha3} from "../src/Sha3.sol";

/// @notice NIST SHA3-256 vectors (FIPS 202) + divergence from EVM-Keccak.
contract Sha3Test is Test {
    function test_empty() public pure {
        // NIST SHA3-256("") = a7ffc6f8...; EVM keccak256("") = c5d24601...
        assertEq(Sha3.hash(""), hex"a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a");
    }

    function test_abc() public pure {
        assertEq(
            Sha3.hash("abc"),
            hex"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
        );
    }

    function test_quickBrownFox() public pure {
        assertEq(
            Sha3.hash("The quick brown fox jumps over the lazy dog"),
            hex"69070dda01975c8c120c3aada1b282394e7f032fa9cf32f4cb2259a0897dfc04"
        );
    }

    function test_divergesFromKeccak() public pure {
        assertTrue(Sha3.hash("abc") != keccak256("abc"));
        assertTrue(Sha3.hash("") != keccak256(""));
    }

    function test_multiblock() public pure {
        // 200 bytes > rate 136: exercises multi-block absorb.
        bytes memory long = new bytes(200);
        for (uint256 i = 0; i < 200; i++) long[i] = bytes1(uint8(i));
        bytes32 h = Sha3.hash(long);
        // Reference: python hashlib.sha3_256(bytes(range(200))).
        assertEq(h, hex"5f728f63bf5ee48c77f453c0490398fa645b8d4c4e56be9a41cfec344d6ca899");
    }
}
