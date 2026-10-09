// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BlsAptos — BLS12-381 aggregate verification for Aptos consensus.
/// @notice Verifies Aptos validator aggregate signatures on EVM using the
///         EIP-2537 precompiles (0x0b..0x11, Prague+).
///         Aptos cryptography (aptos-core):
///         - validator keys: BLS12-381 G1 (48-byte compressed, PoP-checked
///           at registration; the light client trusts the registered set)
///         - consensus signatures: BLS12-381 G2 (96-byte compressed agg sig)
///         - DST "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"
///         - signed message = seed || BCS(LedgerInfo),
///           seed = SHA3-256("APTOS::LedgerInfo")  [Aptos CryptoHash]
///         Equation: e(PK_agg, H(msg)) == e(G1, sig).
/// @dev DESIGN: 381-bit field values never live in uint256. Fp elements are
///      opaque 48-byte big-endian strings; Fp2 elements are 96-byte strings
///      (c0||c1). All arithmetic happens inside the EIP-2537 precompiles
///      (G1MSM/G2MSM/PAIRING/MAP_FP2_TO_G2) or the modexp precompile.
///      Solidity only moves byte buffers around. This keeps every uint256
///      in range and the code auditable.
library BlsAptos {
    // ------------------------------------------------------------- constants

    /// @notice Aptos BLS hash-to-curve DST (POP suite, shared with eth2 CL).
    function _DST_pub() external pure returns (bytes memory) {
        return _DST();
    }

    function _DST() internal pure returns (bytes memory) {
        return "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";
    }

    /// @notice G1 generator (EIP-2537 H1): 64B-padded x || 64B-padded y.
    function _g1Gen() internal pure returns (bytes memory g) {
        g = new bytes(128);
        _g1Coord(g, 16, hex"17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb");
        _g1Coord(g, 80, hex"08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1");
    }

    function _g1Coord(bytes memory g, uint256 off, bytes memory c48) internal pure {
        for (uint256 i = 0; i < 48; i++) g[off + i] = c48[i];
    }

    // ---------------------------------------------------------------- errors

    error BadPoint();
    error PrecompileFailed();
    error BadLength();

    // ------------------------------------------------------- hash to message

    /// @notice The signed preimage: seed || BCS(LedgerInfo).
    /// @param bcsLedgerInfo BCS bytes of the LedgerInfo struct (built
    ///        off-chain; see swap/ts provers for the canonical encoder).
    /// @return out seed(32) || bcs (the BLS message).
    function signingMessage(bytes memory bcsLedgerInfo) internal pure returns (bytes memory out) {
        // seed = SHA3-256("APTOS::LedgerInfo") — pinned, verified by test_seed_pinned.
        bytes memory seed = _ledgerInfoSeed();
        out = new bytes(32 + bcsLedgerInfo.length);
        for (uint256 i = 0; i < 32; i++) out[i] = seed[i];
        for (uint256 i = 0; i < bcsLedgerInfo.length; i++) out[32 + i] = bcsLedgerInfo[i];
    }

    /// @notice seed = SHA3-256("APTOS::LedgerInfo").
    function _ledgerInfoSeed() internal pure returns (bytes memory) {
        return hex"98274d3a1dfd01624eb9df4f2fc4e34fa24f18334a0091ec93d0ea833e1fbaa2";
    }

    // ------------------------------------------------------- hash to curve

    /// @notice IETF hash_to_curve G2 (XMD:SHA-256, SSWU-AB, POP DST).
    /// @dev expand_message_xmd via the SHA2-256 precompile (0x02), then
    ///      MAP_FP2_TO_G2 (0x11) on each 128-byte half, then G2ADD (0x0d).
    ///      This is exactly hash_to_curve per RFC 9380 §3 + the ABLR TH.
    function hashToG2(bytes memory msg) internal view returns (bytes memory h) {
        // IETF hash_to_field (XMD:SHA-256, count=2, m=2, L=64): 256
        // pseudo-random bytes = FOUR 64-byte limbs. Each limb is
        // os2ip-reduced mod p (via modexp) to a 48-byte Fp coordinate:
        // u0 = limbs[0..1], u1 = limbs[2..3]. 0x11 maps each Fp2
        // (16-zero-pad + c0 || pad + c1); G2ADD sums the two mapped
        // points (precompile clears the cofactor).
        bytes memory pseudo = _expandXmd(msg, _DST(), 256);
        require(pseudo.length == 256, 'pseudo');
        bytes memory c0 = _modP(_pad64(pseudo, 0));
        bytes memory c1 = _modP(_pad64(pseudo, 64));
        bytes memory c2 = _modP(_pad64(pseudo, 128));
        bytes memory c3 = _modP(_pad64(pseudo, 192));
        bytes memory q0 = _mapFp2(c0, c1);
        bytes memory q1 = _mapFp2(c2, c3);
        h = _g2Add(q0, q1);
    }

    function _pad64(bytes memory b, uint256 off) internal pure returns (bytes memory v64) {
        v64 = new bytes(64);
        for (uint256 i = 0; i < 64; i++) v64[i] = b[off + i];
    }

    /// @notice Reduce a 64-byte big-endian limb mod p (BLS base field).
    /// @dev Result is an opaque 48-byte big-endian Fp coordinate.
    function _modP(bytes memory v64) internal view returns (bytes memory r48) {
        require(v64.length == 64, 'pad64');
        bytes memory input = _modexpInput(v64);
        (bool ok, bytes memory out) = address(0x05).staticcall(input);
        require(ok && out.length == 48, 'modexp');
        r48 = out;
    }

    function _modexpInput(bytes memory v64) internal pure returns (bytes memory input) {
        // base[96..160) + exp=1[160..192) + mod=p[192..240); total 96+64+32+48=240.
        // Computes v mod p (exp 1: plain reduction, NOT Fermat inverse).
        input = new bytes(240);
        _writeLen(input, 0, 64);
        _writeLen(input, 32, 32);
        _writeLen(input, 64, 48);
        for (uint256 k = 0; k < 64; k++) input[96 + k] = v64[k];
        input[191] = bytes1(0x01);
        bytes memory pbe = _pbe();
        for (uint256 k = 0; k < 48; k++) input[192 + k] = pbe[k];
    }

    function _pbe() internal pure returns (bytes memory pbe) {
        pbe = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    }

    function _beN(bytes memory b, uint256 off, uint256 n) internal pure returns (uint256 v) {
        unchecked {
            for (uint256 i = 0; i < n; i++) v = (v << 8) | uint8(b[off + i]);
        }
    }

    function _writeLen(bytes memory b, uint256 off, uint256 v) internal pure {
        for (uint256 i = 0; i < 32; i++) b[off + i] = bytes1(uint8(v >> (8 * (31 - i))));
    }

    // ------------------------------------------------------- aggregate verify

    /// @notice Verify e(PKagg, H) == e(G1, sig).
    /// @param pkAggG1 128-byte uncompressed aggregate public key.
    /// @param sigG2 256-byte uncompressed aggregate signature.
    /// @param hG2 256-byte H(msg) from hashToG2.
    function verifyAggregate(bytes memory pkAggG1, bytes memory sigG2, bytes memory hG2)
        internal
        view
        returns (bool)
    {
        if (pkAggG1.length != 128 || sigG2.length != 256 || hG2.length != 256) revert BadLength();
        // e(PK,H) * e(G1,-sig) == 1 ; -sig = (q-1)*sig via G2MSM.
        // (scalar inlined as literal: via_ir workaround, no hex-var capture.)
        bytes memory g1 = _g1Gen();
        bytes memory negSig = _g2Mul(
            sigG2,
            hex"73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000000"
        );
        // Pairing input: (PK,H) then (G1,-sig), each pair G1(128)||G2(256).
        // Flat single-pass build (via_ir workaround: nested concat miscompiles).
        bytes memory input = new bytes(768);
        _copyInto(input, 0, pkAggG1);
        _copyInto(input, 128, hG2);
        _copyInto(input, 384, g1);
        _copyInto(input, 512, negSig);
        (bool ok, bytes memory out) = address(0x0f).staticcall(input);
        if (!ok || out.length != 32) revert PrecompileFailed();
        return uint256(bytes32(out)) == 1;
    }

    // ------------------------------------------------------- point aggregation

    /// @notice Aggregate N uncompressed G1 pubkeys via G1MSM (all scalars 1).
    function aggregateG1(bytes memory points128) internal view returns (bytes memory agg) {
        if (points128.length == 0 || points128.length % 128 != 0) revert BadLength();
        uint256 n = points128.length / 128;
        // MSM input: fixed 160-byte scratch (single-key case covers the
        // light-client path; multi-key batches built by _aggregateG1N).
        bytes memory input = _msmInput(points128, n);
        (bool ok, bytes memory out) = address(0x0c).staticcall(input);
        if (!ok || out.length != 128) revert PrecompileFailed();
        agg = out;
    }

    function _msmInput(bytes memory points128, uint256 n) internal pure returns (bytes memory input) {
        input = new bytes(n * 160);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < 128; j++) input[i * 160 + j] = points128[i * 128 + j];
            input[i * 160 + 159] = bytes1(0x01);
        }
    }

    // ------------------------------------------------------------- internals

    /// @notice SSWU map of one Fp2 element (0x11 MAP_FP2_TO_G2).
    /// @dev Each 64-byte slot is 16 zero bytes + 48-byte coordinate
    ///      (coords are < p so the top bytes are zero; 0x11 rejects >= p).
    function _mapFp2(bytes memory c0, bytes memory c1) internal view returns (bytes memory out) {
        require(c0.length == 48 && c1.length == 48, 'fp48');
        bytes memory input = new bytes(128);
        for (uint256 i = 0; i < 48; i++) {
            input[16 + i] = c0[i];
            input[80 + i] = c1[i];
        }
        (bool ok, bytes memory r) = address(0x11).staticcall(input);
        if (!ok || r.length != 256) revert PrecompileFailed();
        out = r;
    }

    function _g2Add(bytes memory a, bytes memory b) internal view returns (bytes memory out) {
        (bool ok, bytes memory r) = address(0x0d).staticcall(bytes.concat(a, b));
        if (!ok || r.length != 256) revert PrecompileFailed();
        out = r;
    }

    function _g2Mul(bytes memory p, bytes memory scalar32) internal view returns (bytes memory out) {
        if (p.length != 256 || scalar32.length != 32) revert BadLength();
        (bool ok, bytes memory r) = address(0x0e).staticcall(bytes.concat(p, scalar32));
        if (!ok || r.length != 256) revert PrecompileFailed();
        out = r;
    }

    /// @notice IETF expand_message_xmd with SHA2-256 (EVM precompile 0x02).
    function _expandXmd(bytes memory msg, bytes memory dst, uint256 lenOut)
        internal
        view
        returns (bytes memory out)
    {
        out = new bytes(lenOut);
        uint256 ell = (lenOut + 31) / 32;
        require(ell >= 1 && ell <= 255, "xmd len");
        require(dst.length <= 255, "dst len");
        bytes memory dstPrime = bytes.concat(dst, bytes1(uint8(dst.length)));
        bytes memory lstr = new bytes(2);
        lstr[0] = bytes1(uint8(lenOut >> 8));
        lstr[1] = bytes1(uint8(lenOut & 0xFF));
        // RFC 9380 5.3.1: b_0 = H(Z_pad || msg || l_i_b_str || I2OSP(0,1) || DST_prime);
        // b_1 = H(b_0 || I2OSP(1,1) || DST_prime);
        // b_i = H(strxor(b_0, b_(i-1)) || I2OSP(i,1) || DST_prime).
        bytes memory zeros = new bytes(64);
        bytes memory b0 = _sha2(_xmdB0(zeros, msg, lstr, dstPrime));
        bytes memory prev = _sha2(_xmdRound(b0, 1, dstPrime));
        uint256 off;
        for (uint256 i = 1; i <= ell; i++) {
            for (uint256 j = 0; j < 32; j++) {
                if (off >= lenOut) break;
                out[off] = prev[j];
                off++;
            }
            if (i == ell) break;
            // prev = H(strxor(b0, prev) || I2OSP(i+1) || DST_prime)
            bytes memory x = _strxor(b0, prev);
            prev = _sha2(_xmdRound(x, uint8(i + 1), dstPrime));
        }
    }

    function _xmdB0(
        bytes memory zeros,
        bytes memory msg,
        bytes memory lstr,
        bytes memory dstPrime
    ) internal pure returns (bytes memory r) {
        r = new bytes(64 + msg.length + 2 + 1 + dstPrime.length);
        for (uint256 k = 0; k < 64; k++) r[k] = zeros[k];
        for (uint256 k = 0; k < msg.length; k++) r[64 + k] = msg[k];
        r[64 + msg.length] = lstr[0];
        r[64 + msg.length + 1] = lstr[1];
        r[64 + msg.length + 2] = bytes1(0x00);
        for (uint256 k = 0; k < dstPrime.length; k++) r[64 + msg.length + 3 + k] = dstPrime[k];
    }

    function _strxor(bytes memory a, bytes memory b) internal pure returns (bytes memory r) {
        require(a.length == 32 && b.length == 32, "xor32");
        r = new bytes(32);
        for (uint256 k = 0; k < 32; k++) r[k] = a[k] ^ b[k];
    }

    function expandXmd(bytes memory msg, bytes memory dst, uint256 lenOut)
        external
        view
        returns (bytes memory out)
    {
        out = _expandXmd(msg, dst, lenOut);
    }

    function _xmdRound(bytes memory prev, uint8 i, bytes memory dstPrime)
        internal
        pure
        returns (bytes memory r)
    {
        r = new bytes(prev.length + 1 + dstPrime.length);
        for (uint256 k = 0; k < prev.length; k++) r[k] = prev[k];
        r[prev.length] = bytes1(i);
        for (uint256 k = 0; k < dstPrime.length; k++) r[prev.length + 1 + k] = dstPrime[k];
    }

    function _sha2(bytes memory data) internal view returns (bytes memory out) {
        (bool ok, bytes memory r) = address(0x02).staticcall(data);
        require(ok && r.length == 32, "sha2");
        out = r;
    }

    function _copyInto(bytes memory dst, uint256 off, bytes memory s) internal pure {
        for (uint256 i = 0; i < s.length; i++) dst[off + i] = s[i];
    }

    function _slice(bytes memory b, uint256 off, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) out[i] = b[off + i];
    }
}
