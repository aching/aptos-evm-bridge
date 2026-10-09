// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Sha3 — NIST SHA3-256 (FIPS 202) in pure Yul-assembly Solidity.
/// @notice Aptos hashes EVERYTHING (BCS seeds, accumulator nodes,
///         hash-to-curve expand_message_xmd) with NIST SHA3-256, whose
///         padding (0x06…0x80) differs from EVM-Keccak (0x01…0x80).
///         solc's keccak256 CANNOT substitute: tests assert divergence.
/// @dev Single-shot for inputs < 200 bytes (covers seeds, node pairs,
///      field elements); streaming `ingest` for longer messages (BCS blobs).
library Sha3 {
    /// @notice Raw Keccak-f[1600] permutation on 25-word state at `st`.
    /// @notice One Keccak-f round, split into phase helpers so each inline
    ///         assembly block stays small (via_ir workaround: one giant
    ///         assembly block misroutes Solidity vars — see Sha3 history).
    // Fixed working area as INTERNAL FUNCTIONS returning literals
    // (via_ir-nightly miscompiles library constants used in code paths).
    function _ST() internal pure returns (uint256) { return 0x1000; }
    function _T() internal pure returns (uint256) { return 0x1000 + 800; }
    function _TH() internal pure returns (uint256) { return 0x1000 + 1120; }
    function _RHO() internal pure returns (uint256) { return 0x1000 + 1440; }
    function _CHI() internal pure returns (uint256) { return 0x1000 + 1760; }

    function keccakF() internal pure {
        for (uint256 r = 0; r < 24; r++) {
            // Theta.
            for (uint256 x = 0; x < 5; x++) {
                uint256 c = _mload(_ST() + x * 32)
                    ^ _mload(_ST() + (x + 5) * 32)
                    ^ _mload(_ST() + (x + 10) * 32)
                    ^ _mload(_ST() + (x + 15) * 32)
                    ^ _mload(_ST() + (x + 20) * 32);
                _mstore(_T() + x * 32, c & 0xFFFFFFFFFFFFFFFF);
            }
            for (uint256 xd = 0; xd < 5; xd++) {
                uint256 cPrev = _mload(_T() + ((xd + 4) % 5) * 32);
                uint256 cNext = _mload(_T() + ((xd + 1) % 5) * 32);
                _mstore(_TH() + xd * 32, (cPrev ^ _rot64(cNext, 1)) & 0xFFFFFFFFFFFFFFFF);
            }
            for (uint256 ii = 0; ii < 25; ii++) {
                uint256 w = _ST() + ii * 32;
                _mstore(w, (_mload(w) ^ _mload(_TH() + (ii % 5) * 32)) & 0xFFFFFFFFFFFFFFFF);
            }
            // Rho + Pi.
            for (uint256 i = 0; i < 25; i++) {
                _mstore(_RHO() + i * 32, _mload(_ST() + i * 32) & 0xFFFFFFFFFFFFFFFF);
            }
            for (uint256 x = 0; x < 5; x++) {
                for (uint256 y = 0; y < 5; y++) {
                    uint256 src = x + y * 5;
                    uint256 dst = y + ((2 * x + 3 * y) % 5) * 5;
                    _mstore(_ST() + dst * 32, _rot64(_mload(_RHO() + src * 32), _roff(x, y)));
                }
            }
            // Chi.
            for (uint256 i = 0; i < 25; i++) {
                _mstore(_CHI() + i * 32, _mload(_ST() + i * 32) & 0xFFFFFFFFFFFFFFFF);
            }
            for (uint256 x = 0; x < 5; x++) {
                for (uint256 y = 0; y < 5; y++) {
                    uint256 b0 = _mload(_CHI() + (x + y * 5) * 32);
                    uint256 b1 = _mload(_CHI() + (((x + 1) % 5) + y * 5) * 32);
                    uint256 b2 = _mload(_CHI() + (((x + 2) % 5) + y * 5) * 32);
                    _mstore(_ST() + (x + y * 5) * 32, (b0 ^ ((~b1) & b2)) & 0xFFFFFFFFFFFFFFFF);
                }
            }
            // Iota.
            _mstore(_ST(), (_mload(_ST()) ^ _rcon(r)) & 0xFFFFFFFFFFFFFFFF);
        }
    }




    function _rot64(uint256 x, uint256 n) internal pure returns (uint256 r) {
        unchecked {
            uint256 nn = n % 64;
            if (nn == 0) return x & 0xFFFFFFFFFFFFFFFF;
            uint256 xx = x & 0xFFFFFFFFFFFFFFFF;
            r = ((xx << nn) | (xx >> (64 - nn))) & 0xFFFFFFFFFFFFFFFF;
        }
    }



    function _roff(uint256 x, uint256 y) internal pure returns (uint256 o) {
        unchecked {
            uint256 t = x * 5 + y;
            if (t == 1) return 36;
            if (t == 2) return 3;
            if (t == 3) return 41;
            if (t == 4) return 18;
            if (t == 5) return 1;
            if (t == 6) return 44;
            if (t == 7) return 10;
            if (t == 8) return 45;
            if (t == 9) return 2;
            if (t == 10) return 62;
            if (t == 11) return 6;
            if (t == 12) return 43;
            if (t == 13) return 15;
            if (t == 14) return 61;
            if (t == 15) return 28;
            if (t == 16) return 55;
            if (t == 17) return 25;
            if (t == 18) return 21;
            if (t == 19) return 56;
            if (t == 20) return 27;
            if (t == 21) return 20;
            if (t == 22) return 39;
            if (t == 23) return 8;
            if (t == 24) return 14;
            return 0;
        }
    }





    function _rcon(uint256 r) internal pure returns (uint256 c) {
        if (r == 0) return 0x0000000000000001;
        if (r == 1) return 0x0000000000008082;
        if (r == 2) return 0x800000000000808a;
        if (r == 3) return 0x8000000080008000;
        if (r == 4) return 0x000000000000808b;
        if (r == 5) return 0x0000000080000001;
        if (r == 6) return 0x8000000080008081;
        if (r == 7) return 0x8000000000008009;
        if (r == 8) return 0x000000000000008a;
        if (r == 9) return 0x0000000000000088;
        if (r == 10) return 0x0000000080008009;
        if (r == 11) return 0x000000008000000a;
        if (r == 12) return 0x000000008000808b;
        if (r == 13) return 0x800000000000008b;
        if (r == 14) return 0x8000000000008089;
        if (r == 15) return 0x8000000000008003;
        if (r == 16) return 0x8000000000008002;
        if (r == 17) return 0x8000000000000080;
        if (r == 18) return 0x000000000000800a;
        if (r == 19) return 0x800000008000000a;
        if (r == 20) return 0x8000000080008081;
        if (r == 21) return 0x8000000000008080;
        if (r == 22) return 0x0000000080000001;
        if (r == 23) return 0x8000000080008008;
        revert("bad round");
    }

    /// @notice SHA3-256 of arbitrary bytes (streaming, any length).
    /// @dev Block loop lives in Solidity (Yul cannot call keccakF); the
    ///      per-block XOR and the tail/pad stay in assembly helpers.
    ///      LANE PACKING: Keccak lanes are 64-bit LE. EVM words are 256-bit
    ///      BE. Lane i (bytes [8i,8i+8) of the stream) is stored as the LOW
    ///      64 bits of EVM word (st + 8i): i.e. word k holds lanes
    ///      [4k, 4k+4) in its 4 LE 64-bit sub-words. All helpers use this.
    function _permute(uint256 st) internal pure {
        for (uint256 i = 0; i < 25; i++) {
            _mstore(_ST() + i * 32, _mload(st + i * 32) & 0xFFFFFFFFFFFFFFFF);
        }
        keccakF();
        for (uint256 i = 0; i < 25; i++) {
            _mstore(st + i * 32, _mload(_ST() + i * 32) & 0xFFFFFFFFFFFFFFFF);
        }
    }

    function hash(bytes memory data) internal pure returns (bytes32 out) {
        // Word-spaced lanes throughout: lane i at 0x2000 + i*32 (value in LOW 64 bits).
        uint256 len = data.length;
        uint256 ptr = _dataPtr(data, 0);
        uint256 full = len - (len % 136);
        for (uint256 i = 0; i < full; i += 136) {
            for (uint256 li = 0; li < 17; li++) {
                _mstore(0x2000 + li * 32, (_mload(0x2000 + li * 32) ^ _loadLane(ptr + i, li)) & 0xFFFFFFFFFFFFFFFF);
            }
            _permute(0x2000);
        }
        uint256 t = _dataPtr(data, full);
        uint256 rem = len - full;
        for (uint256 bi = 0; bi < rem; bi++) {
            uint256 w = 0x2000 + (bi / 8) * 32;
            _mstore(w, _mload(w) ^ (_byteAt(t, bi) << (8 * (bi % 8))));
        }
        // Pad: 0x06 XOR stream byte rem; 0x80 XOR stream byte 135.
        // LE lane packing: stream byte b = lane (b/8) LE-byte (b%8) = bits [8*(b%8)..].
        uint256 w06 = 0x2000 + (rem / 8) * 32;
        _mstore(w06, _mload(w06) ^ (uint256(0x06) << (8 * (rem % 8))));
        _mstore(0x2000 + 512, _mload(0x2000 + 512) ^ (uint256(0x80) << 56));
        _permute(0x2000);
        out = squeezeWord(0x2000, 0);
    }

    function _loadLane(uint256 ptr, uint256 i) internal pure returns (uint256 lane) {
        unchecked {
            // LE lane: byte j of the 8-byte window = bits [8j, 8j+8) of lane.
            uint256 src = ptr + i * 8;
            uint256 acc;
            for (uint256 j = 0; j < 8; j++) {
                acc |= _byteAt(src, j) << (8 * j);
            }
            lane = acc;
        }
    }

    function _mload(uint256 a) internal pure returns (uint256 v) {
        assembly {
            v := mload(a)
        }
    }

    function _xorLane(uint256 st, uint256 i, uint256 lane) internal pure {
        unchecked {
            uint256 w = st + i * 8;
            uint256 cur = _mload(w);
            _mstore(w, (cur & ~uint256(0xFFFFFFFFFFFFFFFF)) | ((cur ^ lane) & uint256(0xFFFFFFFFFFFFFFFF)));
        }
    }

    function _mstore(uint256 a, uint256 v) internal pure {
        assembly {
            mstore(a, v)
        }
    }

    /// @notice XOR tail bytes + SHA3 pad + final permutation.
    function _absorbTail(uint256, bytes memory, uint256, uint256) internal pure {
        revert('inlined');
    }

    function _dataPtr(bytes memory data, uint256 full) internal pure returns (uint256 t) {
        t = _ptrOf(data) + 0x20 + full;
    }

    function _ptrOf(bytes memory data) internal pure returns (uint256 p) {
        // via_ir workaround: copy the pointer through memory instead of
        // referencing the Solidity variable inside assembly.
        uint256[1] memory box;
        assembly {
            mstore(box, data)
            p := mload(box)
        }
    }

    function _byteAt(uint256 t, uint256 i) internal pure returns (uint256 b) {
        assembly {
            b := byte(0, mload(add(t, i)))
        }
    }

    function _xorLaneByte(uint256 st, uint256 lane, uint256 pos, uint256 b) internal pure {
        uint256 w = st + lane * 8;
        uint256 shift = 8 * (24 - pos);
        _mstore(w, _mload(w) ^ (b << shift));
    }

    /// @notice Squeeze 32 bytes: state bytes [0..32) in stream order.
    function squeezeWord(uint256 st, uint256 k) internal pure returns (bytes32 out) {
        // LE lanes: output byte 8i+j = lane-i LE byte j = (lane >> 8j) & FF.
        // Output word is BE: byte [8j..8j+8) holds lane j's bytes in order,
        // i.e. acc |= lane << 8*(24-8j) with lane bytes already LE-within-lane.
        // Lane value V holds stream bytes LE: V byte j (from LSB) = stream byte.
        // Output BE byte (8j+m) must equal stream byte = (V >> 8m)&FF, i.e.
        // output word = bswap64(V) placed at BE position: sw = bswap(V).
        uint256 acc;
        for (uint256 j = 0; j < 4; j++) {
            uint256 lane = _mload(st + (k * 4 + j) * 32) & 0xFFFFFFFFFFFFFFFF;
            uint256 sw;
            for (uint256 bb = 0; bb < 8; bb++) {
                sw |= ((lane >> (8 * bb)) & 0xFF) << (8 * (7 - bb));
            }
            acc |= sw << (8 * (24 - j * 8));
        }
        out = bytes32(acc);
    }

    function newState() internal pure returns (uint256 st) {
        // Fixed dynamic-state area (via_ir workaround: the free-memory
        // pointer value misroutes through internal calls; literals work).
        st = 0x2000;
    }
}
