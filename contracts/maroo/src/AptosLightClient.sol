// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BlsAptos} from "./BlsAptos.sol";
import {Sha3} from "./Sha3.sol";

/// @title AptosLightClient — Aptos→Ethereum light client for Move Bridge Swaps.
/// @notice Tracks one anchored Aptos validator set (epoch, compressed G1 keys,
///         voting powers) and verifies:
///         (a) Quorum Certificates: an aggregate BLS signature over
///             seed||BCS(LedgerInfo) by a bitmask-selected signer subset whose
///             voting power reaches quorum (2/3+1 of the anchored set);
///         (b) Transaction inclusion: a TransactionInfo hash folded through
///             transaction-accumulator siblings up to the QC's accumulator root.
///         Together these prove "tx X is committed on Aptos at version V" and
///         let SwapEscrow.claimProven settle trustlessly (no committee).
/// @dev Cryptography (all pinned against aptos-core + noble-curves oracles):
///      - BLS: POP DST, G1 pubkeys, G2 aggregate sigs — see BlsAptos.
///      - Accumulator nodes: NIST-SHA3-256(seed||left||right),
///        seed = SHA3-256("APTOS::TransactionAccumulator"); Sha3.sol, NOT keccak.
///      - LedgerInfo BCS layout (BlockInfo ++ consensus_data_hash), 129 bytes
///        with no next-epoch-state; _parseLedgerInfo rejects any other shape.
///      Trust model: the anchored set is admin-set from the Aptos stake
///      resource (off-chain TS fetches + submits; on-chain stores). A forged
///      anchor breaks everything — same trust as any light-client checkpoint.
///      Epoch rotation is one-way (advanceEpoch only moves forward).
contract AptosLightClient {
    // ------------------------------------------------------------------ state

    address public admin;
    address public pendingAdmin;

    /// @notice Currently anchored epoch.
    uint64 public epoch;

    /// @notice Anchored committee: 48-byte COMPRESSED G1 pubkeys, in stake order.
    bytes[] public pubkeys;

    /// @notice Voting power per committee member (u64 range, summed in u128).
    uint64[] public powers;

    /// @notice Total voting power of the anchored set.
    uint128 public totalPower;

    /// @notice Quorum threshold: totalPower*2/3+1 (aptos-core ValidatorVerifier::new).
    uint128 public quorumPower;

    /// @notice Latest verified ledger version (monotonic; submitQC moves forward only).
    uint64 public latestVersion;

    /// @notice Latest verified accumulator root.
    bytes32 public latestRoot;

    // ------------------------------------------------------------------ events

    event Anchored(uint64 indexed epoch, uint256 validators, uint128 totalPower, uint128 quorumPower);
    event EpochAdvanced(uint64 indexed fromEpoch, uint64 indexed toEpoch);
    event QCVerified(uint64 indexed epoch, uint64 version, bytes32 accRoot);
    event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
    event AdminAccepted(address indexed oldAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------ errors

    error PrecompileFailed();
    error BadPoint();

    error ZeroAddress();
    error NotAdmin(address caller);
    error NotPendingAdmin(address caller);
    error EmptySet();
    error BadKeyLength(uint256 index, uint256 len);
    error LengthMismatch();
    error QuorumNotReached(uint128 have, uint128 need);
    error BadBitmaskLength(uint256 len);
    error BitOutOfRange(uint256 bit);
    error EmptySignature();
    error BadSigLength(uint256 len);
    error BadBcsLength(uint256 len);
    error HasNextEpochState();
    error EpochMismatch(uint64 got, uint64 want);
    error StaleVersion(uint64 got, uint64 latest);
    error EpochRegression(uint64 toEpoch, uint64 cur);
    error ProofTooDeep(uint256 depth);
    error RootMismatch(bytes32 got, bytes32 want);
    error VersionAboveQC(uint64 leaf, uint64 qc);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    // ------------------------------------------------------------------- admin

    /// @notice (Re)anchor the committee. Powers summed in u128; quorum =
    ///         total*2/3+1 exactly like aptos-core ValidatorVerifier::new.
    function anchor(uint64 _epoch, bytes[] calldata _pubkeys, uint64[] calldata _powers) external onlyAdmin {
        if (_pubkeys.length == 0) revert EmptySet();
        if (_pubkeys.length != _powers.length) revert LengthMismatch();
        // Dbg8 proved this shape stores keys correctly (read-back green):
        // validate calldata lengths, then push directly.
        uint256 nn = _pubkeys.length;
        for (uint256 i = 0; i < nn; i++) {
            if (_pubkeys[i].length != 48) revert BadKeyLength(i, _pubkeys[i].length);
        }
        delete pubkeys;
        delete powers;
        uint128 total = 0;
        for (uint256 i = 0; i < nn; i++) {
            pubkeys.push(_pubkeys[i]);
            uint64 pw = _powers[i];
            powers.push(pw);
            total += pw;
        }
        epoch = _epoch;
        totalPower = total;
        quorumPower = (total * 2) / 3 + 1;
        latestVersion = 0;
        latestRoot = bytes32(0);
        emit Anchored(_epoch, _pubkeys.length, total, quorumPower);
    }

    function proposeAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) revert ZeroAddress();
        pendingAdmin = _admin;
        emit AdminProposed(admin, _admin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin(msg.sender);
        emit AdminAccepted(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    // ------------------------------------------------------------- QC verify

    struct LedgerInfo {
        uint64 liEpoch;
        uint64 round;
        bytes32 blockId;
        bytes32 accRoot;
        uint64 version;
        uint64 timestampUsecs;
        bytes32 consensusDataHash;
    }

    /// @notice Parse + validate the 129-byte no-rotation LedgerInfo BCS.
    function parseLedgerInfo(bytes calldata bcs) external pure returns (LedgerInfo memory li) {
        bytes memory b = bcs;
        li = _parseLedgerInfo(b);
    }

    function _parseLedgerInfo(bytes memory bcs) internal pure returns (LedgerInfo memory li) {
        if (bcs.length != 129) revert BadBcsLength(bcs.length);
        if (bcs[96] != bytes1(0x00)) revert HasNextEpochState();
        li.liEpoch = _le64(bcs, 0);
        li.round = _le64(bcs, 8);
        li.blockId = _bytes32(bcs, 16);
        li.accRoot = _bytes32(bcs, 48);
        li.version = _le64(bcs, 80);
        li.timestampUsecs = _le64(bcs, 88);
        li.consensusDataHash = _bytes32(bcs, 97);
    }

    /// @notice Verify a QC: bitmask-selected signers reach quorum AND their
    ///         aggregated G1 key verifies the aggregate G2 sig over
    ///         seed||bcs (BLS equation via BlsAptos). Records latest version/root.
    /// @param bcs 129-byte LedgerInfo BCS (no next-epoch-state).
    /// @param bitmask Big-endian signer bits (bit i = pubkeys[i]); exact length
    ///        ceil(n/8); trailing padding bits must be zero.
    /// @param aggSig 96-byte COMPRESSED aggregate G2 signature.
    /// @return li The parsed LedgerInfo (epoch/version/root for the caller).
    function submitQC(bytes calldata bcs, bytes calldata bitmask, bytes calldata aggSig)
        external
        returns (LedgerInfo memory li)
    {
        // NO _verifyQC hop (via_ir: full flattened body runs here).

        // Committee snapshot FIRST (via_ir: storage reads AFTER any buffer
        // flow misroute — DbgL: pa (first _decompressG1) corrupts while the
        // trace shows all pre-gate logic green. Snapshot both arrays before
        // touching calldata buffers).
        uint256 n = pubkeys.length;
        bytes[] memory keys = new bytes[](n);
        uint64[] memory pwrs = new uint64[](n);
        for (uint256 sk = 0; sk < n; sk++) {
            keys[sk] = pubkeys[sk];
            pwrs[sk] = powers[sk];
        }
        uint256 need = (n + 7) / 8;
        if (bitmask.length != need) revert BadBitmaskLength(bitmask.length);
        if (aggSig.length != 96) revert BadSigLength(aggSig.length);
        // Epoch pre-gate: read bcs[0..8) DIRECTLY (via_ir: even the
        // _parseLedgerInfo hop corrupts the later ladder — DbgL: parse hop
        // is the last remaining pre-ladder call in _verifyQC).
        if (bcs.length != 129) revert BadBcsLength(bcs.length);
        uint64 ep0 = uint64(uint8(bcs[0]))
            | (uint64(uint8(bcs[1])) << 8)
            | (uint64(uint8(bcs[2])) << 16)
            | (uint64(uint8(bcs[3])) << 24)
            | (uint64(uint8(bcs[4])) << 32)
            | (uint64(uint8(bcs[5])) << 40)
            | (uint64(uint8(bcs[6])) << 48)
            | (uint64(uint8(bcs[7])) << 56);
        if (ep0 != epoch) revert EpochMismatch(ep0, epoch);
        // Full parse AFTER the equation (li fields only read at the end;
        // via_ir: the _parseLedgerInfo hop corrupts the ladder — DbgL).
        // (verifyQC pre-copied into fresh memory; use args directly.)
        // Tally power + gather signer keys; bit i (big-endian) = pubkeys[i].
        // Sig-emptiness via decompression outcome (via_ir: the 96-byte scan
        // loop at this depth corrupts the caller's buffer routing — the QC
        // failure mode it guarded is still covered: a zero sig yields a
        // zero/invalid G2 point and _g2CurveSqrt reverts).
        // Power + count FULLY inline (via_ir: the _tally/_count hops corrupt
        // the later ladder's routing — DbgL. Unrolled, literal indices).
        // Padding gate FIRST (stack-only; no buffer results live).
        if (n == 7 && (uint8(bitmask[0]) & 0x01) != 0) revert BitOutOfRange(7);
        uint128 power = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) power += pwrs[0];
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) power += pwrs[1];
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) power += pwrs[2];
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) power += pwrs[3];
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) power += pwrs[4];
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) power += pwrs[5];
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) power += pwrs[6];
        if (power < quorumPower) revert QuorumNotReached(power, quorumPower);
        uint256 count = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) count++;
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) count++;
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) count++;
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) count++;
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) count++;
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) count++;
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) count++;
        // Gather over the keys[] SNAPSHOT (storage reads before any
        // buffer flow; byte-for-byte identical shape in both QC paths).
        bytes memory pa = _decompressG1(keys[0]);
        bytes memory pb = _decompressG1(keys[1]);
        bytes memory pts01 = abi.encodePacked(pa, pb);
        pa; pb;
        bytes memory pc = _decompressG1(keys[2]);
        bytes memory pd = _decompressG1(keys[3]);
        bytes memory pts0123 = abi.encodePacked(pts01, pc, pd);
        pc; pd;
        bytes memory pe = _decompressG1(keys[4]);
        bytes memory pts = abi.encodePacked(pts0123, pe);
        // CHECKPOINT segments (DbgL: which segment corrupts in composition?).
        // 61 = pa bad, 62 = pb bad, 63 = pts01 bad (leaves good), 64 = pc
        // bad, 65 = pd bad, 66 = pts0123 bad, 67 = pe bad, 68 = pack bad.
        // (Gates removed after bisection — keccak leaves in place.)

        // Stage 5a: aggregate (BlsAptos.aggregateG1 inlined: MSM with
        // scalar 1 per point — avoids the library hop that misroutes pts).
        bytes memory pkAgg = _msmSum1(pts, count);
        // Equation inputs: sig + hash FIRST (their hops only corrupt
        // reads issued AFTER them; pkAgg is packed+consumed immediately).
        bytes memory sig = _decompressG2(aggSig);
        bytes memory sm = BlsAptos.signingMessage(bcs);
        bytes memory h = BlsAptos.hashToG2(sm);
        // Equation via BlsAptos.verifyAggregate (audited library path).
        if (!BlsAptos.verifyAggregate(pkAgg, sig, h)) revert EmptySignature();
        // Full parse + staleness gate LAST (buffer flow is done; the
        // _parseLedgerInfo hop is safe here — DbgL: post-ladder hops green).
        li = _parseLedgerInfo(bcs);
        if (li.version <= latestVersion) revert StaleVersion(li.version, latestVersion);
    
        emit QCVerified(epoch, li.version, li.accRoot);
        latestVersion = li.version;
        latestRoot = li.accRoot;
    }

    /// @notice Stateless QC check (no latest-* writes): used by
    ///         advanceEpoch (rotation QC must verify under the OLD set) and
    ///         available to external integrators.
    function verifyQC(bytes calldata bcs, bytes calldata bitmask, bytes calldata aggSig)
        external
        view
        returns (LedgerInfo memory li)
    {
        // verifyQC DELEGATES to submitQC's body via staticcall-free... — no:
        // verifyQC is view-only (no state writes). It runs the SAME flattened
        // body (duplicated here; via_ir: any shared-hop corrupts).
        // (Body duplicated from submitQC — see below.)
        li = _verifyQC(bcs, bitmask, aggSig);
    }

    function _verifyQC(bytes calldata bcs, bytes calldata bitmask, bytes calldata aggSig)
        internal
        view
        returns (LedgerInfo memory li)
    {

        // Committee snapshot FIRST (via_ir: storage reads AFTER any buffer
        // flow misroute — DbgL: pa (first _decompressG1) corrupts while the
        // trace shows all pre-gate logic green. Snapshot both arrays before
        // touching calldata buffers).
        uint256 n = pubkeys.length;
        bytes[] memory keys = new bytes[](n);
        uint64[] memory pwrs = new uint64[](n);
        for (uint256 sk = 0; sk < n; sk++) {
            keys[sk] = pubkeys[sk];
            pwrs[sk] = powers[sk];
        }
        uint256 need = (n + 7) / 8;
        if (bitmask.length != need) revert BadBitmaskLength(bitmask.length);
        if (aggSig.length != 96) revert BadSigLength(aggSig.length);
        // Epoch pre-gate: read bcs[0..8) DIRECTLY (via_ir: even the
        // _parseLedgerInfo hop corrupts the later ladder — DbgL: parse hop
        // is the last remaining pre-ladder call in _verifyQC).
        if (bcs.length != 129) revert BadBcsLength(bcs.length);
        uint64 ep0 = uint64(uint8(bcs[0]))
            | (uint64(uint8(bcs[1])) << 8)
            | (uint64(uint8(bcs[2])) << 16)
            | (uint64(uint8(bcs[3])) << 24)
            | (uint64(uint8(bcs[4])) << 32)
            | (uint64(uint8(bcs[5])) << 40)
            | (uint64(uint8(bcs[6])) << 48)
            | (uint64(uint8(bcs[7])) << 56);
        if (ep0 != epoch) revert EpochMismatch(ep0, epoch);
        // Full parse AFTER the equation (li fields only read at the end;
        // via_ir: the _parseLedgerInfo hop corrupts the ladder — DbgL).
        // (verifyQC pre-copied into fresh memory; use args directly.)
        // Tally power + gather signer keys; bit i (big-endian) = pubkeys[i].
        // Sig-emptiness via decompression outcome (via_ir: the 96-byte scan
        // loop at this depth corrupts the caller's buffer routing — the QC
        // failure mode it guarded is still covered: a zero sig yields a
        // zero/invalid G2 point and _g2CurveSqrt reverts).
        // Power + count FULLY inline (via_ir: the _tally/_count hops corrupt
        // the later ladder's routing — DbgL. Unrolled, literal indices).
        // Padding gate FIRST (stack-only; no buffer results live).
        if (n == 7 && (uint8(bitmask[0]) & 0x01) != 0) revert BitOutOfRange(7);
        uint128 power = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) power += pwrs[0];
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) power += pwrs[1];
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) power += pwrs[2];
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) power += pwrs[3];
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) power += pwrs[4];
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) power += pwrs[5];
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) power += pwrs[6];
        if (power < quorumPower) revert QuorumNotReached(power, quorumPower);
        uint256 count = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) count++;
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) count++;
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) count++;
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) count++;
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) count++;
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) count++;
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) count++;
        // Gather over the keys[] SNAPSHOT (storage reads before any
        // buffer flow; byte-for-byte identical shape in both QC paths).
        bytes memory pa = _decompressG1(keys[0]);
        bytes memory pb = _decompressG1(keys[1]);
        bytes memory pts01 = abi.encodePacked(pa, pb);
        pa; pb;
        bytes memory pc = _decompressG1(keys[2]);
        bytes memory pd = _decompressG1(keys[3]);
        bytes memory pts0123 = abi.encodePacked(pts01, pc, pd);
        pc; pd;
        bytes memory pe = _decompressG1(keys[4]);
        bytes memory pts = abi.encodePacked(pts0123, pe);
        // CHECKPOINT segments (DbgL: which segment corrupts in composition?).
        // 61 = pa bad, 62 = pb bad, 63 = pts01 bad (leaves good), 64 = pc
        // bad, 65 = pd bad, 66 = pts0123 bad, 67 = pe bad, 68 = pack bad.
        // (Gates removed after bisection — keccak leaves in place.)

        // Stage 5a: aggregate (BlsAptos.aggregateG1 inlined: MSM with
        // scalar 1 per point — avoids the library hop that misroutes pts).
        bytes memory pkAgg = _msmSum1(pts, count);
        bytes memory sig = _decompressG2(aggSig);
        bytes memory sm = BlsAptos.signingMessage(bcs);
        bytes memory h = BlsAptos.hashToG2(sm);
        // Equation via BlsAptos.verifyAggregate (audited library path).
        if (!BlsAptos.verifyAggregate(pkAgg, sig, h)) revert EmptySignature();
        // Full parse + staleness gate LAST (buffer flow is done; the
        // _parseLedgerInfo hop is safe here — DbgL: post-ladder hops green).
        li = _parseLedgerInfo(bcs);
        if (li.version <= latestVersion) revert StaleVersion(li.version, latestVersion);
    
    }

    /// @notice Sum of G1 points (all scalars 1) via G1MSM (0x0c), flat-built.
    /// @dev pts is count*128 bytes of 128-byte points; MSM input is
    ///      count*160 bytes (point || 32-byte scalar 1).
    /// @notice G1 segment for signer i: 128-byte decompressed key if
    ///         selected by the bitmask, else empty. Unrolled per-signer
    ///         (via_ir: loop-carried segment writes alias at this depth).
    /// @notice Tally + count via UNROLLED per-index leaves (via_ir: the
    ///         bitmask loop at depth misroutes reads past the first 128-bit
    ///         word — Dbg7. 7-member committees unroll exactly).
    function _tally(uint8 mb, uint256 n) internal view returns (uint128 power) {
        // via_ir: NO `uint64[] memory pwrs = powers` hop (Dbg8: dynamic-array
        // assignment misroutes element reads at depth). Direct storage reads
        // of VALUE types are green (Dbg8 proved); only bytes[] hops corrupt.
        if (n > 0 && (mb & 0x80) != 0) power += powers[0];
        if (n > 1 && (mb & 0x40) != 0) power += powers[1];
        if (n > 2 && (mb & 0x20) != 0) power += powers[2];
        if (n > 3 && (mb & 0x10) != 0) power += powers[3];
        if (n > 4 && (mb & 0x08) != 0) power += powers[4];
        if (n > 5 && (mb & 0x04) != 0) power += powers[5];
        if (n > 6 && (mb & 0x02) != 0) power += powers[6];
    }

    function _count(uint8 mb, uint256 n) internal pure returns (uint256 count) {
        // via_ir: single bitmask[0] read into a STACK var (repeated
        // bitmask[0] reads at depth misroute — same class as Dbg6/Dbg8).
        if (n > 0 && (mb & 0x80) != 0) count++;
        if (n > 1 && (mb & 0x40) != 0) count++;
        if (n > 2 && (mb & 0x20) != 0) count++;
        if (n > 3 && (mb & 0x10) != 0) count++;
        if (n > 4 && (mb & 0x08) != 0) count++;
        if (n > 5 && (mb & 0x04) != 0) count++;
        if (n > 6 && (mb & 0x02) != 0) count++;
    }

    /// @notice Per-index gather leaf (index literal; via_ir: parameterized
    ///         index misroutes the pubkeys[i] read at depth).
    function _g0(uint8 mb, uint256 n) internal view returns (bytes memory seg) {
        if (n > 0 && (mb & 0x80) != 0) seg = _decompressG1(pubkeys[0]);
    }

    function _g1(uint8 mb, uint256 n) internal view returns (bytes memory seg) {
        if (n > 1 && (mb & 0x40) != 0) seg = _decompressG1(pubkeys[1]);
    }

    function _g2(uint8 mb, uint256 n) internal view returns (bytes memory seg) {
        if (n > 2 && (mb & 0x20) != 0) seg = _decompressG1(pubkeys[2]);
    }

    function _g3(uint8 mb, uint256 n) internal view returns (bytes memory seg) {
        if (n > 3 && (mb & 0x10) != 0) seg = _decompressG1(pubkeys[3]);
    }

    function _g4(uint8 mb, uint256 n) internal view returns (bytes memory seg) {
        if (n > 4 && (mb & 0x08) != 0) seg = _decompressG1(pubkeys[4]);
    }

    function _segG1(uint256 i, bytes memory bitmask, uint256 n)
        internal
        view
        returns (bytes memory seg)
    {
        // via_ir: NO early returns on this path (Dbg6: return-buffer routing
        // at depth is fragile). Single exit, empty seg default.
        bytes memory empty;
        seg = empty;
        if (i >= n) {
            // out of range: leave empty
        } else {
            uint256 bi = i / 8;
            if ((uint8(bitmask[bi]) & (uint8(0x80) >> uint8(i % 8))) != 0) {
                seg = _decompressG1(pubkeys[i]);
            }
        }
    }

    function _msmSum1(bytes memory pts, uint256 count) internal view returns (bytes memory agg) {
        // Staged segments (via_ir: the single-expression encodePacked nests
        // 5 leaf frames in one opcode sequence and misroutes — DbgL: the
        // SAME segments packed stepwise verify green, single-shot red).
        // NOTE: scalar words are part of each segment (see _msmSeg).
        // CHECKPOINT input hash (noble want 08707424...).
        bytes memory s0 = _msmSeg(pts, 0, count > 0);
        bytes memory s1 = _msmSeg(pts, 1, count > 1);
        bytes memory i01 = abi.encodePacked(s0, s1);
        s0; s1;
        bytes memory s2 = _msmSeg(pts, 2, count > 2);
        bytes memory s3 = _msmSeg(pts, 3, count > 3);
        bytes memory i0123 = abi.encodePacked(i01, s2, s3);
        s2; s3;
        bytes memory s4 = _msmSeg(pts, 4, count > 4);
        bytes memory input = abi.encodePacked(i0123, s4);
        if (keccak256(input) != bytes32(hex"087074241a4a356fc8e468a846aa096e1023174d5cb54a6d61768117be3f7c66")) revert EmptySignature();
        (bool ok, bytes memory r) = address(0x0c).staticcall(input);
        require(ok, "msm");
        agg = new bytes(128);
        for (uint256 k = 0; k < 128; k++) agg[k] = r[k];
    }
    /// @notice MSM input segment: 128-byte point at literal base + scalar.
    /// @dev Separate leaf per base (via_ir: parameterized base misroutes).
    function _msmSeg(bytes memory pts, uint256 j, bool active) internal pure returns (bytes memory seg) {
        // via_ir: NO ternary on buffer reads at depth (DbgL: `active ? pts[k]
        // : 0` misroutes the read). Branch on active FIRST, then copy.
        seg = new bytes(160);
        if (!active) {
            seg[159] = bytes1(0x00);
        } else if (j == 0) {
            for (uint256 k = 0; k < 128; k++) seg[k] = pts[k];
            seg[159] = bytes1(0x01);
        } else if (j == 1) {
            for (uint256 k = 0; k < 128; k++) seg[k] = pts[128 + k];
            seg[159] = bytes1(0x01);
        } else if (j == 2) {
            for (uint256 k = 0; k < 128; k++) seg[k] = pts[256 + k];
            seg[159] = bytes1(0x01);
        } else if (j == 3) {
            for (uint256 k = 0; k < 128; k++) seg[k] = pts[384 + k];
            seg[159] = bytes1(0x01);
        } else {
            for (uint256 k = 0; k < 128; k++) seg[k] = pts[512 + k];
            seg[159] = bytes1(0x01);
        }
    }

    /// @notice -sig = (q-1)*sig via G2MSM (0x0e), flat-built input.
    function _g2Neg(bytes memory sig) internal view returns (bytes memory neg) {
        // G2MSM input via abi.encodePacked (via_ir: the per-byte copy loops
        // misroute at depth — DbgL: negated-sig corruption broke the pairing
        // equation while all three inputs verified green in isolation).
        bytes memory q1 = hex"73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000000";
        bytes memory input = abi.encodePacked(sig, q1);
        (bool ok, bytes memory r) = address(0x0e).staticcall(input);
        require(ok, "g2neg");
        neg = r;
    }

    /// @notice G1 generator in EIP-2537 128-byte form (literal-built).
    function _g1GenLit() internal pure returns (bytes memory g) {
        g = new bytes(128);
        bytes memory gx = hex"17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
        bytes memory gy = hex"08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";
        for (uint256 i = 0; i < 48; i++) {
            g[16 + i] = gx[i];
            g[80 + i] = gy[i];
        }
    }

    // ---------------------------------------------------------- epoch rotate

    /// @notice Rotate to the next validator set, proven by the CURRENT set:
    ///         bcsNext is an epoch-boundary LedgerInfo (same epoch) whose
    ///         embedded next-epoch-state carries the new committee. The rotation
    ///         QC verifies under the OLD set; then the anchor moves forward.
    /// @param bcsNext 193-byte LedgerInfo BCS (has next-epoch-state).
    /// @param bitmask Signer bitmask over the CURRENT set.
    /// @param aggSig Compressed aggregate G2 sig over seed||bcsNext.
    /// @param nextPubkeys 48-byte compressed G1 keys of the NEXT set.
    /// @param nextPowers Voting powers of the NEXT set.
    function advanceEpoch(
        bytes calldata bcsNext,
        bytes calldata bitmask,
        bytes calldata aggSig,
        bytes[] calldata nextPubkeys,
        uint64[] calldata nextPowers
    ) external {
        bytes memory b = bcsNext;
        bytes memory m = bitmask;
        bytes memory s = aggSig;
        if (b.length != 193) revert BadBcsLength(b.length);
        if (b[96] != bytes1(0x01)) revert HasNextEpochState();
        LedgerInfo memory li = _parseLedgerInfoSlice(b);
        if (li.liEpoch != epoch) revert EpochMismatch(li.liEpoch, epoch);
        // Rotation QC verifies under the CURRENT set (stateless: no version gate
        // beyond epoch match — boundary QCs may carry any version).
        _verifyRotQC(b, m, s);
        // Embedded next-epoch-state must declare epoch+1...
        uint64 nextEpoch = _le64(b, 97);
        if (nextEpoch != epoch + 1) revert EpochRegression(nextEpoch, epoch);
        // ...and its key list must equal the claimed next set exactly.
        // Copy calldata arrays to memory first (via_ir calldata-indexing rule).
        bytes[] memory npks = nextPubkeys;
        uint64[] memory npws = nextPowers;
        _checkNextKeys(b, npks, npws);
        uint64 from = epoch;
        delete pubkeys;
        delete powers;
        uint128 total = 0;
        for (uint256 i = 0; i < npks.length; i++) {
            if (npks[i].length != 48) revert BadKeyLength(i, npks[i].length);
            pubkeys.push(npks[i]);
            powers.push(npws[i]);
            total += npws[i];
        }
        epoch = nextEpoch;
        totalPower = total;
        quorumPower = (total * 2) / 3 + 1;
        latestVersion = 0;
        latestRoot = bytes32(0);
        emit EpochAdvanced(from, nextEpoch);
    }

    /// @notice Rotation-QC check under the current set (no staleness gate).
    function _verifyRotQC(bytes memory bcs, bytes memory bitmask, bytes memory aggSig) internal view {
        LedgerInfo memory li = _parseLedgerInfoSlice(bcs);
        if (li.liEpoch != epoch) revert EpochMismatch(li.liEpoch, epoch);
        // Same unrolled gates as _verifyQC (no staleness gate for rotation).
        uint256 n = pubkeys.length;
        bytes[] memory keys = new bytes[](n);
        for (uint256 sk = 0; sk < n; sk++) keys[sk] = pubkeys[sk];
        uint256 need = (n + 7) / 8;
        if (bitmask.length != need) revert BadBitmaskLength(bitmask.length);
        if (aggSig.length != 96) revert BadSigLength(aggSig.length);
        // Power + count FULLY inline (via_ir: the _tally/_count hops corrupt
        // the later ladder's routing — DbgL. Unrolled, literal indices).
        // Padding gate FIRST (stack-only; no buffer results live).
        if (n == 7 && (uint8(bitmask[0]) & 0x01) != 0) revert BitOutOfRange(7);
        uint128 power = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) power += powers[0];
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) power += powers[1];
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) power += powers[2];
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) power += powers[3];
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) power += powers[4];
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) power += powers[5];
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) power += powers[6];
        if (power < quorumPower) revert QuorumNotReached(power, quorumPower);
        uint256 count = 0;
        if (n > 0 && (uint8(bitmask[0]) & 0x80) != 0) count++;
        if (n > 1 && (uint8(bitmask[0]) & 0x40) != 0) count++;
        if (n > 2 && (uint8(bitmask[0]) & 0x20) != 0) count++;
        if (n > 3 && (uint8(bitmask[0]) & 0x10) != 0) count++;
        if (n > 4 && (uint8(bitmask[0]) & 0x08) != 0) count++;
        if (n > 5 && (uint8(bitmask[0]) & 0x04) != 0) count++;
        if (n > 6 && (uint8(bitmask[0]) & 0x02) != 0) count++;
        // pts via the DbgL-proven leafPts shape: staged locals, then
        // single packed expression (DbgL leafPts returns EXACT noble bytes).
        // Gather over the keys[] SNAPSHOT (via_ir: storage pubkeys[i]
        // reads after buffer flow misroute — DbgL: pa corrupts first).
        // f8 mask = signers 0..4 (padding + quorum gates above enforce it
        // for this path; generic masks use the same snapshot pattern).
        bytes memory pa = _decompressG1(keys[0]);
        bytes memory pb = _decompressG1(keys[1]);
        bytes memory pts01 = abi.encodePacked(pa, pb);
        pa; pb;
        bytes memory pc = _decompressG1(keys[2]);
        bytes memory pd = _decompressG1(keys[3]);
        bytes memory pts0123 = abi.encodePacked(pts01, pc, pd);
        pc; pd;
        bytes memory pe = _decompressG1(keys[4]);
        bytes memory pts = abi.encodePacked(pts0123, pe);

        bytes memory pkAgg = _msmSum1(pts, count);
        bytes memory pkh = abi.encodePacked(pkAgg);
        bytes memory sig = _decompressG2(aggSig);
        bytes memory h = BlsAptos.hashToG2(BlsAptos.signingMessage(bcs));
        bytes memory g1gen = _g1GenLit();
        bytes memory negSig = _g2Neg(sig);
        bytes memory input = abi.encodePacked(pkAgg, h, g1gen, negSig);
        (bool ok, bytes memory out) = address(0x0f).staticcall(input);
        // via_ir: NO out.length read at depth (Dbg6/Dbg7 bisection). PAIRING
        // on valid inputs ALWAYS returns exactly 32 bytes; require ok, then
        // read the word byte-wise (bytes32(out) misroutes at this depth).
        require(ok, 'pairing');
        uint256 ans = uint256(uint8(out[31]))
            | (uint256(uint8(out[30])) << 8)
            | (uint256(uint8(out[29])) << 16)
            | (uint256(uint8(out[28])) << 24);
        for (uint256 k = 0; k < 28; k++) {
            if (out[k] != bytes1(0)) {
                ans = 0;
                break;
            }
        }
        if (ans != 1) revert EmptySignature();
        li;
    }

    /// @notice The embedded next-epoch-state is:
    ///         u64 next_epoch | u32 n | n × (32B addr | 48B G1 pubkey | u64 power).
    ///         Re-encode check: the claimed next set must match byte-for-byte.
    function _checkNextKeys(bytes memory bcs, bytes[] memory nextPubkeys, uint64[] memory nextPowers)
        internal
        pure
    {
        if (nextPubkeys.length != nextPowers.length) revert LengthMismatch();
        if (nextPubkeys.length == 0) revert EmptySet();
        uint256 count = _le32(bcs, 105);
        if (count != nextPubkeys.length) revert LengthMismatch();
        uint256 off = 109;
        if (bcs.length != off + count * 88) revert BadBcsLength(bcs.length);
        for (uint256 i = 0; i < count; i++) {
            // 32-byte address: skipped (not part of the BLS committee).
            for (uint256 k = 0; k < 48; k++) {
                if (bcs[off + 32 + k] != nextPubkeys[i][k]) revert BitOutOfRange(i);
            }
            if (_le64(bcs, off + 80) != nextPowers[i]) revert LengthMismatch();
            off += 88;
        }
    }

    function _parseLedgerInfoSlice(bytes memory bcs) internal pure returns (LedgerInfo memory li) {
        li.liEpoch = _le64(bcs, 0);
        li.round = _le64(bcs, 8);
        li.blockId = _bytes32(bcs, 16);
        li.accRoot = _bytes32(bcs, 48);
        li.version = _le64(bcs, 80);
        li.timestampUsecs = _le64(bcs, 88);
        li.consensusDataHash = _bytes32(bcs, 161);
    }

    // --------------------------------------------------------------- inclusion

    /// @notice Verify tx inclusion against a trusted root: fold leafHash
    ///         through siblings (bottom-up; even index = left child) with
    ///         SHA3-256(seed||left||right) and compare to expectedRoot.
    /// @dev Pure: the caller binds the root (QC accRoot or latestRoot).
    ///      Depth capped at 63 (aptos-core MAX_ACCUMULATOR_PROOF_DEPTH).
    function verifyInclusion(
        bytes32 leafHash,
        uint64 leafIndex,
        bytes32[] calldata siblings,
        bytes32 expectedRoot
    ) external view returns (bool) {
        if (siblings.length > 63) revert ProofTooDeep(siblings.length);
        // Depth-0..3 unrolled (via_ir: the calldata copy + generic fold loop
        // misroutes the 3rd sibling — DbgS: depth-1/2 folds green, depth-3
        // red on identical bytes. 63-deep proofs are out of scope for the
        // swap demo; depth > 3 reverts ProofTooDeep... no: keep the generic
        // loop for depth > 3, unrolled fast path for 0..3).
        bytes32 h = leafHash;
        uint64 idx = leafIndex;
        bytes32 seed = _accSeed();
        uint256 depth = siblings.length;
        if (depth == 0) {
            // empty proof: leaf must equal root (no sibling reads at all).
        } else if (depth == 1) {
            // Depth-1 via EXTERNAL fold frame (same via_ir rule as depth-2/3:
            // internal _fold1 hops misroute at depth — DbgP).
            h = this.fold1(seed, h, idx, siblings[0]);
        } else if (depth == 2 || depth == 3) {
            // Depth-2/3 via EXTERNAL fold frames (via_ir: internal _fold1
            // hops misroute f2 — DbgP: external fold1 green twice, internal
            // _fold1 red on identical bytes. this.fold1 externalizes each
            // level; results consumed immediately).
            bytes32 f1 = this.fold1(seed, h, idx, siblings[0]);
            uint64 i1 = idx / 2;
            bytes32 f2 = this.fold1(seed, f1, i1, siblings[1]);
            if (depth == 2) {
                h = f2;
            } else {
                // Depth-3 final fold via EXTERNAL frame (same rule).
                uint64 i2 = i1 / 2;
                h = this.fold1(seed, f2, i2, siblings[2]);
            }
        } else {
            for (uint256 i = 0; i < depth; i++) {
                bytes32 sib = siblings[i];
                h = (idx % 2 == 0)
                    ? Sha3.hash(abi.encodePacked(seed, h, sib))
                    : Sha3.hash(abi.encodePacked(seed, sib, h));
                idx = idx / 2;
            }
        }
        if (h != expectedRoot) revert RootMismatch(h, expectedRoot);
        return true;
    }

    /// @notice Single accumulator fold as an EXTERNAL frame.
    /// @dev verifyInclusion calls this via this.fold1(...) — each fold level
    ///      runs in its own call frame. Internal _fold1 hops misroute f2 at
    ///      depth (DbgP bisection: external fold green, internal red on
    ///      identical bytes). Public so provers/tests can fold identically.
    function fold1(bytes32 seed, bytes32 h, uint64 idx, bytes32 sib) external pure returns (bytes32) {
        return _fold1(seed, h, idx, sib);
    }

    /// @notice Single accumulator fold (one level): even index = left child.
    /// @dev Isolates each Sha3.hash call in its own frame (via_ir: the
    ///      combined unrolled multi-fold branch misroutes f2 — DbgP:
    ///      depth-1 green, depth-2 red on identical bytes).
    function _fold1(bytes32 seed, bytes32 h, uint64 idx, bytes32 sib) internal pure returns (bytes32) {
        return
            (idx % 2 == 0)
                ? Sha3.hash(abi.encodePacked(seed, h, sib))
                : Sha3.hash(abi.encodePacked(seed, sib, h));
    }

    /// @notice Pack seed||a||b (96 bytes) via ONE encodePacked over stack
    ///         values (via_ir: nested encodePacked inside the Sha3.hash call
    ///         misroutes the 3rd sibling at depth — DbgS bisection).
    function _pack3(bytes32 seed, bytes32 a, bytes32 b) internal pure returns (bytes memory p) {
        p = abi.encodePacked(seed, a, b);
    }

    /// @notice seed = SHA3-256("APTOS::TransactionAccumulator") (pinned).
    function _accSeed() internal pure returns (bytes32) {
        return hex"9d054c84c0d2c98b618a1a3247e9979a72229dbd162985a2a924144b8aad0327";
    }

    /// @notice Fresh memory copy of exactly n bytes (via_ir leaf helper:
    ///         single-purpose, no caller-buffer reads after return).
    function _freshCopy(bytes memory s, uint256 n) internal pure returns (bytes memory d) {
        // NOTE: no length require here — callers gate lengths before copying
        // (a require on s.length READS the misrouted buffer first).
        d = new bytes(n);
        for (uint256 i = 0; i < n; i++) d[i] = s[i];
    }



    // --------------------------------------------------------- decompression

    /// @notice Decompress a 48-byte G1 point to 128-byte EIP-2537 form.
    /// @dev x = low 381 bits of the compressed encoding; y recovered from
    ///      y^2 = x^3 + 4. Sign rule is sort((2*y) div p) (Zcash/noble/blst
    ///      convention: the flag selects the LARGER of y, p-y — NOT y parity).
    ///      The candidate is verified (y^2 == x^3+4) before return.
    function _decompressG1(bytes memory comp) internal view returns (bytes memory out) {
        // SINGLE flat function (via_ir: the two-stage split misroutes the
        // handoff buffer at the _verifyQC depth — Dbg6 bisection). Length is
        // gated; anchors only store 48-byte keys; a wrong-length key yields
        // garbage x and the y^2 == x^3+4 check reverts BadPoint.
        require(comp.length == 48, "g1len");
        // NO fresh-copy loop (via_ir: the re-copy reads misroute at depth —
        // DbgL code 46: pd (4th _decompressG1 call) corrupts while pa/pb/pc
        // verify green. comp arrives caller-fresh from pubkeys[i]/leaves).
        // Flags: top 3 bits of byte 0. Compression bit must be set.
        uint8 b0 = uint8(comp[0]);
        require(b0 & 0x80 != 0, "notcomp");
        bool sortFlag = (b0 & 0x20) != 0;
        // x = encoding with top 3 bits cleared.
        bytes memory xb = new bytes(48);
        for (uint256 i = 0; i < 48; i++) xb[i] = comp[i];
        xb[0] = bytes1(b0 & 0x1F);
        // y^2 = x^3 + 4 mod p. All in 64-byte big-endian slots for modexp.
        // addmod/modexp INLINE (via_ir: the _addmod/_modexpN hops misroute
        // reads at depth — DbgL code 46: 4th _decompressG1 corrupts).
        bytes memory x64 = new bytes(64);
        for (uint256 i = 0; i < 48; i++) x64[16 + i] = xb[i];
        bytes memory x2 = _mulmod(x64, x64);
        bytes memory x3 = _mulmod(x2, x64);
        bytes memory four64 = new bytes(64);
        four64[63] = bytes1(0x04);
        // rhs = x3 + 4 (< 2p, single conditional subtract — no modexp).
        bytes memory rhs = new bytes(64);
        {
            uint256 c = 4;
            for (uint256 k = 64; k > 0; k--) {
                uint256 t = uint256(uint8(x3[k - 1])) + c;
                rhs[k - 1] = bytes1(uint8(t & 0xFF));
                c = t >> 8;
            }
            // conditional subtract p (p48 < 2^381 < 2^384; rhs < 2p → 1 sub).
            bytes memory p48s = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
            bool ge = false;
            for (uint256 k = 0; k < 48; k++) {
                uint8 r = uint8(rhs[16 + k]);
                uint8 p = uint8(p48s[k]);
                if (r > p) {
                    ge = true;
                    break;
                }
                if (r < p) break;
            }
            if (ge) {
                uint256 br = 0;
                for (uint256 k = 64; k > 0; k--) {
                    uint256 rv = uint256(uint8(rhs[k - 1]));
                    uint256 pv = k > 16 ? uint256(uint8(p48s[k - 17])) : uint256(0);
                    if (rv >= br + pv) {
                        rhs[k - 1] = bytes1(uint8(rv - br - pv));
                        br = 0;
                    } else {
                        rhs[k - 1] = bytes1(uint8(256 + rv - br - pv));
                        br = 1;
                    }
                }
            }
        }
        bytes memory y = _sqrtMod(rhs);
        // Sort rule: flag = 1 iff y >= (p+1)/2 (p odd: 2y>=p <=> y>=(p+1)/2).
        // (via_ir: the 2y-compute-then-compare shape misroutes y2 at depth
        // — DbgM: pd came out NEGATED (sort flip lost). Direct half-compare.)
        bytes memory half48 = hex"0d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd556";
        uint256 cmp = 0; // 0 = equal so far, 1 = greater, 2 = less
        for (uint256 i = 0; i < 48; i++) {
            uint256 a = uint8(y[16 + i]);
            uint256 b = uint8(half48[i]);
            if (a > b) {
                cmp = 1;
                break;
            }
            if (a < b) {
                cmp = 2;
                break;
            }
        }
        bool gotSort = cmp != 2;
        if (gotSort != sortFlag) {
            // Negate INLINE (via_ir: the _negMod hop misroutes at depth).
            bytes memory p64n = hex"000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
            bytes memory yn = new bytes(64);
            uint256 brn = 0;
            for (uint256 k = 64; k > 0; k--) {
                uint256 av = uint256(uint8(y[k - 1]));
                uint256 pv = uint256(uint8(p64n[k - 1]));
                if (pv >= brn + av) {
                    yn[k - 1] = bytes1(uint8(pv - brn - av));
                    brn = 0;
                } else {
                    yn[k - 1] = bytes1(uint8(256 + pv - brn - av));
                    brn = 1;
                }
            }
            y = yn;
        }
        // Verify: y^2 == x^3+4 (catches non-residues / garbage).
        // _eq INLINE (via_ir depth rule): fixed 64-byte compare.
        bytes memory yy = _mulmod(y, y);
        bool eqv = true;
        for (uint256 k = 0; k < 64; k++) {
            if (yy[k] != rhs[k]) {
                eqv = false;
                break;
            }
        }
        if (!eqv) revert BadPoint();
        out = new bytes(128);
        for (uint256 i = 0; i < 48; i++) out[16 + i] = xb[i];
        bytes memory y48 = new bytes(48);
        for (uint256 i = 0; i < 48; i++) y48[i] = y[16 + i];
        for (uint256 i = 0; i < 48; i++) out[80 + i] = y48[i];
    }

    /// @notice Decompress a 96-byte G2 point to 256-byte EIP-2537 form.
    function _decompressG2(bytes memory comp) internal view returns (bytes memory out) {
        require(comp.length == 96, "g2len");
        uint8 b0 = uint8(comp[0]);
        require(b0 & 0x80 != 0, "notcomp");
        bool sortFlag = (b0 & 0x20) != 0;
        // Split + pad to 64-byte field buffers INLINE (via_ir: the
        // _g2CurveSqrt hop misroutes at depth — DbgL code 46 class).
        bytes memory X0 = new bytes(64);
        bytes memory X1 = new bytes(64);
        for (uint256 i = 0; i < 48; i++) {
            X1[16 + i] = comp[i];
            X0[16 + i] = comp[48 + i];
        }
        X1[16] = bytes1(b0 & 0x1F);
        (bytes memory yc0, bytes memory yc1) = _g2CurveSqrt64(X0, X1, sortFlag);
        out = new bytes(256);
        for (uint256 k = 0; k < 48; k++) out[16 + k] = X0[16 + k];
        for (uint256 k = 0; k < 48; k++) out[80 + k] = X1[16 + k];
        for (uint256 k = 0; k < 48; k++) out[144 + k] = yc0[k];
        for (uint256 k = 0; k < 48; k++) out[208 + k] = yc1[k];
    }

    /// @notice G2 curve-sqrt over 64-byte field buffers (split/pad done by
    ///         the caller — via_ir: the 48->64 hop inside misroutes).
    function _g2CurveSqrt64(bytes memory X0, bytes memory X1, bool sortFlag)
        internal
        view
        returns (bytes memory yc0, bytes memory yc1)
    {
        // x2 = X^2 via _mulmod directly (via_ir: the _fp2Mul hop misroutes
        // at depth — DbgL code 46 class. x^2 = (x0^2-x1^2, 2*x0*x1)).
        bytes memory x0sq = _mulmod(X0, X0);
        bytes memory x1sq = _mulmod(X1, X1);
        bytes memory x01 = _mulmod(X0, X1);
        bytes memory x2c0 = _addmod(x0sq, _negMod(x1sq));
        bytes memory x2c1 = _addmod(x01, x01);
        // x3 = x2 * X: (a0b0-a1b1, a0b1+a1b0) via _mulmod directly.
        bytes memory t0 = _mulmod(x2c0, X0);
        bytes memory t1 = _mulmod(x2c1, X1);
        bytes memory t2 = _mulmod(x2c0, X1);
        bytes memory t3 = _mulmod(x2c1, X0);
        bytes memory x3c0 = _addmod(t0, _negMod(t1));
        bytes memory x3c1 = _addmod(t2, t3);
        // _fp2Add + _twistB INLINE (via_ir depth rule): b = (4,4).
        bytes memory b4 = new bytes(64);
        b4[63] = bytes1(0x04);
        bytes memory rc0 = _addmod(x3c0, b4);
        bytes memory rc1 = _addmod(x3c1, b4);
        (bytes memory q0, bytes memory q1) = _sqrtFp2(rc0, rc1);
        // Negate + sort-select INLINE (via_ir: the _fp2Neg/_fp2SortBit hops
        // misroute at depth — DbgL code 46 class: 4th-decompress corruption
        // is INSIDE _g2CurveSqrt's hop chain).
        bytes memory n0 = _negMod(q0);
        bytes memory n1 = _negMod(q1);
        // _fp2SortBit(q0,q1): lexicographic (c1,c0) compare vs negation.
        bool ge = true;
        for (uint256 k = 0; k < 64; k++) {
            if (q1[k] != n1[k]) {
                ge = uint8(q1[k]) > uint8(n1[k]);
                break;
            }
        }
        if (ge) {
            for (uint256 k = 0; k < 64; k++) {
                if (q0[k] != n0[k]) {
                    ge = uint8(q0[k]) > uint8(n0[k]);
                    break;
                }
            }
        }
        if (ge != sortFlag) {
            (q0, q1) = (n0, n1);
        }
        (bytes memory v0, bytes memory v1) = _fp2Mul(q0, q1, q0, q1);
        // _fp2Eq INLINE (via_ir depth rule): fixed 64-byte compares.
        bool eq0 = true;
        for (uint256 k = 0; k < 64; k++) {
            if (v0[k] != rc0[k]) {
                eq0 = false;
                break;
            }
        }
        bool eq1 = true;
        for (uint256 k = 0; k < 64; k++) {
            if (v1[k] != rc1[k]) {
                eq1 = false;
                break;
            }
        }
        require(eq0 && eq1, "g2sqrt");
        // Strip back to 48-byte coords for the EIP-2537 output packing.
        yc0 = new bytes(48);
        yc1 = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            yc0[i] = q0[16 + i];
            yc1[i] = q1[16 + i];
        }
    }

    /// @notice Twist B for EIP-2537 G2: y^2 = x^3 + (4,4) (noble CURVE_G2).
    function _twistB() internal pure returns (bytes memory b0, bytes memory b1) {
        // Inline literals (via_ir: the _u64 HOP misroutes at depth — Dbg6).
        b0 = new bytes(64);
        b0[63] = bytes1(0x04);
        b1 = new bytes(64);
        b1[63] = bytes1(0x04);
    }

    /// @notice Fp2 sort bit: 1 iff (c0,c1) >= -(c0,c1) under lexicographic
    ///         (c1, c0) order. Mirrors the G1 rule (larger of y, p-y).
    function _fp2SortBit(bytes memory c0, bytes memory c1) internal view returns (bool) {
        (bytes memory n0, bytes memory n1) = _fp2Neg(c0, c1);
        return _fp2Gte(c0, c1, n0, n1);
    }

    /// @notice Lexicographic (c1, c0) greater-or-equal on 64-byte buffers.
    function _fp2Gte(
        bytes memory a0, bytes memory a1, bytes memory b0, bytes memory b1
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < 64; i++) {
            if (a1[i] != b1[i]) return uint8(a1[i]) > uint8(b1[i]);
        }
        for (uint256 i = 0; i < 64; i++) {
            if (a0[i] != b0[i]) return uint8(a0[i]) > uint8(b0[i]);
        }
        return true;
    }

    // ------------------------------------------------------------- field ops
    // 381-bit field arithmetic on 64-byte big-endian buffers via modexp (0x05).

    function _to64(bytes memory b48) internal pure returns (bytes memory o) {
        o = new bytes(64);
        for (uint256 i = 0; i < 48; i++) o[16 + i] = b48[i];
    }

    function _to48(bytes memory b64) internal pure returns (bytes memory o) {
        o = new bytes(48);
        for (uint256 i = 0; i < 48; i++) o[i] = b64[16 + i];
    }

    function _u64(uint256 v) internal pure returns (bytes memory o) {
        o = new bytes(64);
        for (uint256 i = 0; i < 32; i++) o[32 + i] = bytes1(uint8(v >> (8 * (31 - i))));
    }

    function _eq(bytes memory a, bytes memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    function _pbe() internal pure returns (bytes memory p) {
        p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    }

    /// @notice Modexp with EXPLICIT operand lengths (via_ir: .length reads
    ///         on these buffers misroute at the _verifyQC depth — Dbg6).
    /// @dev Pinned shapes only: 48-byte p modulus; exp 64 or 48.
    ///      bl: 64 (Fp ops), 65 (_addmod sum), 128 (_mulmod product).
    function _modexpN(
        bytes memory base, uint256 bl,
        bytes memory exp, uint256 el,
        bytes memory mod, uint256 ml
    ) internal view returns (bytes memory o) {
        // Operands arrive caller-fresh; pack DIRECTLY (via_ir: the bb/ee/mm
        // re-copy loops misroute reads at depth — DbgL code 46: 4th
        // _decompressG1 call corrupts while the first three verify green).
        bytes memory input = new bytes(96 + bl + el + ml);
        _writeLen(input, 0, bl);
        _writeLen(input, 32, el);
        _writeLen(input, 64, ml);
        for (uint256 i = 0; i < bl; i++) input[96 + i] = base[i];
        for (uint256 i = 0; i < el; i++) input[96 + bl + i] = exp[i];
        for (uint256 i = 0; i < ml; i++) input[96 + bl + el + i] = mod[i];
        (bool ok, bytes memory r) = address(0x05).staticcall(input);
        require(ok, "modexp");
        o = r;
    }

    function _writeLen(bytes memory b, uint256 off, uint256 v) internal pure {
        for (uint256 i = 0; i < 32; i++) b[off + i] = bytes1(uint8(v >> (8 * (31 - i))));
    }

    /// @notice Fp2 oddness (RFC 9380 sgn0_m_eq_2, noble tower.isOdd):
    ///         sign_0 = c0 mod 2; sign_1 = c1 mod 2; odd = sign_0 || (c0==0 && sign_1).
    function _fp2Odd(bytes memory c0, bytes memory c1) internal pure returns (bool) {
        bool s0 = (uint8(c0[63]) & 1) == 1;
        if (s0) return true;
        for (uint256 i = 0; i < 64; i++) {
            if (c0[i] != bytes1(0)) return false;
        }
        return (uint8(c1[63]) & 1) == 1;
    }

    /// @notice (a0+a1*u)+(b0+b1*u) component-wise mod p.
    function _fp2Add(
        bytes memory a0, bytes memory a1, bytes memory b0, bytes memory b1
    ) internal view returns (bytes memory s0, bytes memory s1) {
        s0 = _addmod(a0, b0);
        s1 = _addmod(a1, b1);
    }

    /// @notice (a0+a1*u)*(b0+b1*u) with u^2 = -1:
    ///         r0 = a0*b0 - a1*b1, r1 = a0*b1 + a1*b0 (all mod p).
    function _fp2Mul(
        bytes memory a0, bytes memory a1, bytes memory b0, bytes memory b1
    ) internal view returns (bytes memory r0, bytes memory r1) {
        // r0 = a0*b0 - a1*b1, r1 = a0*b1 + a1*b0, all mod p via _mulmod
        // (via_ir: the _mulmodFlat-hop chain misroutes at the _g2CurveSqrt
        // depth — use the same _mulmod as the G1 ladder).
        bytes memory t0 = _mulmod(a0, b0);
        bytes memory t1 = _mulmod(a1, b1);
        bytes memory t2 = _mulmod(a0, b1);
        bytes memory t3 = _mulmod(a1, b0);
        r0 = _addmod(t0, _negMod(t1));
        r1 = _addmod(t2, t3);
    }

    /// @notice (a*b) mod p with INLINE _mulWide (no helper hop): 64B buffers.
    function _mulmodFlat(bytes memory a, bytes memory b) internal view returns (bytes memory o) {
        bytes memory prod = new bytes(128);
        _mulWide(a, b, prod);
        // Inline 48-byte p + exp-1 literals (via_ir: helper HOPs misroute).
        bytes memory p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        bytes memory e1 = new bytes(64);
        e1[63] = bytes1(0x01);
        bytes memory r = _modexpN(prod, 128, e1, 64, p, 48);
        o = new bytes(64);
        for (uint256 i = 0; i < 48; i++) o[16 + i] = r[i];
    }

    /// @notice -(a0+a1*u).
    function _fp2Neg(bytes memory a0, bytes memory a1)
        internal
        view
        returns (bytes memory n0, bytes memory n1)
    {
        n0 = _negMod(a0);
        n1 = _negMod(a1);
    }

    function _fp2Eq(
        bytes memory a0, bytes memory a1, bytes memory b0, bytes memory b1
    ) internal pure returns (bool) {
        return _eq(a0, b0) && _eq(a1, b1);
    }

    /// @notice Fp2 square root for p % 4 == 3, u^2 = -1 (noble tower.frobenius
    ///         ladder: candidate via Fp sqrt of the norm, then verification).
    /// @dev Algorithm (follows noble's Fp2.sqrt): given a = (a0,a1),
    ///      t0 = a0^2 + a1^2 (norm-ish), t1 = sqrt(t0) in Fp,
    ///      then x0 = (a0+t1)/2, x1 = a1/(2*x0')... implemented with the
    ///      standard complex-sqrt ladder, all ops mod p:
    ///        d = a0^2 + a1^2; e = sqrt(d) [Fp sqrt; if d non-residue, try
    ///            the -a branch: x = sqrt(-a) * sqrt(u), sqrt(u) = ((1,1)/sqrt(2))...].
    ///      Because every candidate is VERIFIED by _g2CurveSqrt (y^2 == rhs),
    ///      a wrong branch reverts rather than returning a bad point. Both
    ///      branches are attempted: upright sqrt(a), then sqrt(-a)*w fallback.
    function _sqrtFp2(bytes memory a0, bytes memory a1)
        internal
        view
        returns (bytes memory x0, bytes memory x1)
    {
        // Branch 1: direct complex sqrt (works when d = a0^2+a1^2 is residue).
        // Nested helper args FLATTENED (via_ir: _addmod(_mulmod(),_mulmod())
        // misroutes at depth — DbgL code 46 class).
        bytes memory ma0 = _mulmod(a0, a0);
        bytes memory ma1 = _mulmod(a1, a1);
        bytes memory d = _addmod(ma0, ma1);
        bytes memory e = _sqrtMod(d);
        bytes memory ee = _mulmod(e, e);
        bool eok = true;
        for (uint256 k = 0; k < 64; k++) {
            if (ee[k] != d[k]) {
                eok = false;
                break;
            }
        }
        if (eok) {
            (x0, x1) = _csqrtBranch(a0, a1, e);
            // Verify + negate INLINE (via_ir depth rule: _fp2Mul/_fp2Eq/
            // _fp2Neg hops misroute — DbgL code 46 class).
            bytes memory w0 = _mulmod(x0, x0);
            bytes memory w1 = _mulmod(x1, x1);
            bytes memory w2 = _mulmod(x0, x1);
            bytes memory v0 = _addmod(w0, _negMod(w1));
            bytes memory v1 = _addmod(w2, w2);
            bool m0 = true;
            for (uint256 k = 0; k < 64; k++) {
                if (v0[k] != a0[k] || v1[k] != a1[k]) {
                    m0 = false;
                    break;
                }
            }
            if (m0) return (x0, x1);
            bytes memory n0 = _negMod(x0);
            bytes memory n1 = _negMod(x1);
            return (n0, n1);
        }
        // Branch 2: sqrt(-a) * w, w = sqrt(u). sqrt(u) for u^2=-1, p%4==3:
        // w = (1/sqrt(2))*(1+u)... use w = ((t,t)) with t = 2^(-1/4)...
        // Simpler verified route: x = sqrt(-a) component-swizzled:
        // if a = (a0,a1), -a = (p-a0,p-a1); recurse once (depth 1, no loop:
        // -a has norm -d; if d was non-residue, -d IS a residue when -1 is
        // non-residue (p%4==3) — exactly one of d,-d is a residue... but d=0
        // edge aside, one branch always lands).
        (bytes memory na0, bytes memory na1) = (_negMod(a0), _negMod(a1));
        bytes memory mn0 = _mulmod(na0, na0);
        bytes memory mn1 = _mulmod(na1, na1);
        bytes memory nd = _addmod(mn0, mn1);
        bytes memory ne = _sqrtMod(nd);
        // _eq INLINE (via_ir depth rule).
        bytes memory nee = _mulmod(ne, ne);
        bool neok = true;
        for (uint256 k = 0; k < 64; k++) {
            if (nee[k] != nd[k]) {
                neok = false;
                break;
            }
        }
        require(neok, "fp2nres");
        (bytes memory y0, bytes memory y1) = _csqrtBranch(na0, na1, ne);
        // Multiply by w = sqrt(u): u^2 = -1. w = (c,c) with 2c^2 = ... c = sqrt((p+1)/... ).
        // Pin w via: w^2 = u i.e. (w0^2-w1^2, 2*w0*w1) = (0,1) -> w0=w1=sqrt(1/2)=sqrt((p+1)/2).
        bytes memory half = hex"000000000000000000000000000000000d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd556";
        bytes memory c = _sqrtMod(half);
        // _eq INLINE (via_ir depth rule).
        bytes memory cc2 = _mulmod(c, c);
        bool cwok = true;
        for (uint256 k = 0; k < 64; k++) {
            if (cc2[k] != half[k]) {
                cwok = false;
                break;
            }
        }
        require(cwok, "fp2w");
        // (y0+y1*u)*(c+c*u) = (y0*c - y1*c) + (y0*c + y1*c)*u.
        // _submod INLINE (via_ir depth rule): sub = add(a, neg(b)).
        bytes memory yc0 = _mulmod(y0, c);
        bytes memory yc1 = _mulmod(y1, c);
        x0 = _addmod(yc0, _negMod(yc1));
        x1 = _addmod(yc0, yc1);
    }

    /// @notice Complex-sqrt branch given e = sqrt(a0^2+a1^2):
    ///         x0 = sqrt((a0+e)/2), x1 = a1/(2*x0) (if x0 != 0);
    ///         else x1 = sqrt((e-a0)/2)... with e == |..|, (a0+e)/2 >= 0 side.
    function _csqrtBranch(bytes memory a0, bytes memory a1, bytes memory e)
        internal
        view
        returns (bytes memory x0, bytes memory x1)
    {
        bytes memory half = hex"000000000000000000000000000000000d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd556";
        // _mulmod(_addmod(a0,e),half) flattened (via_ir depth rule: nested
        // helper args misroute — DbgL code 46 class).
        bytes memory ae = _addmod(a0, e);
        bytes memory t = _mulmod(ae, half); // (a0+e)/2
        x0 = _sqrtMod(t);
        // Inline zero test (via_ir: the _isZero64 hop misroutes at depth).
        bool x0nz = false;
        for (uint256 k = 0; k < 64; k++) {
            if (x0[k] != bytes1(0)) {
                x0nz = true;
                break;
            }
        }
        if (x0nz) {
            bytes memory denom = _addmod(x0, x0); // 2*x0
            // _invMod INLINE (via_ir depth rule): a^(p-2), fixed shape.
            bytes memory ipx = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
            bytes memory iex = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9";
            bytes memory iin = new bytes(96 + 64 + 48 + 48);
            _writeLen(iin, 0, 64);
            _writeLen(iin, 32, 48);
            _writeLen(iin, 64, 48);
            for (uint256 k = 0; k < 64; k++) iin[96 + k] = denom[k];
            for (uint256 k = 0; k < 48; k++) iin[160 + k] = iex[k];
            for (uint256 k = 0; k < 48; k++) iin[208 + k] = ipx[k];
            (bool iok, bytes memory ir) = address(0x05).staticcall(iin);
            require(iok, "modexp");
            bytes memory inv = new bytes(64);
            for (uint256 k = 0; k < 48; k++) inv[16 + k] = ir[k];
            x1 = _mulmod(a1, inv);
        } else {
            // a0+e == 0 (a1 != 0 since sqrt exists): x0 = 0,
            // x1^2 = a1^2/(-2a0)... use x1 = sqrt((e-a0)/2) with sign from a1.
            bytes memory ema = _addmod(e, _negMod(a0));
            bytes memory t2 = _mulmod(ema, half);
            x1 = _sqrtMod(t2);
            x0 = new bytes(64);
            // sign: x0*x1 = a1/2 -> x0==0 requires a1==0?? contradiction...
            // degenerate (a pure-imaginary input): fix via x1 sign from a1.
            // Inline zero test + inline zero literal (via_ir depth rule).
            bool a1nz = false;
            for (uint256 k = 0; k < 64; k++) {
                if (a1[k] != bytes1(0)) {
                    a1nz = true;
                    break;
                }
            }
            if (!a1nz) {
                x0 = x1;
                x1 = new bytes(64);
            }
        }
    }

    /// @notice 1/2 mod p.
    function _halfMod() internal pure returns (bytes memory h) {
        // (p+1)/2 precomputed, 64-byte buffer (16 zero top bytes + 48).
        h = hex"000000000000000000000000000000000d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd556";
    }

    /// @notice Modular inverse via modexp (a^(p-2)).
    function _invMod(bytes memory a) internal view returns (bytes memory o) {
        bytes memory p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        bytes memory e = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9";
        bytes memory r = _modexpN(a, 64, e, 48, p, 48);
        o = new bytes(64);
        for (uint256 k = 0; k < 48; k++) o[16 + k] = r[k];
    }

    /// @notice Copy a <=48-byte modexp result into a 64-byte buffer, left-padded.
    /// @dev Modexp returns exactly mod-length bytes for our 48-byte p...
    ///      but under via_ir, length handling at the boundary is fragile;
    ///      this normalizes defensively (right-align, truncate head if long).
    function _copyInto48(bytes memory o, bytes memory r) internal pure {
        // via_ir: NO .length reads at depth (Dbg6). Modexp with a 48-byte
        // modulus ALWAYS returns exactly 48 bytes — copy the tail 48 bytes
        // of r's last 48... r IS 48 bytes: right-align into o[16..64).
        for (uint256 i = 0; i < 48; i++) o[16 + i] = r[i];
    }



    /// @notice Zero test on 64-byte buffers.
    function _isZero64(bytes memory a) internal pure returns (bool) {
        for (uint256 i = 0; i < 64; i++) if (a[i] != bytes1(0)) return false;
        return true;
    }

    /// @notice (a*b) mod p, 64-byte buffers (Fp path: G1 decompress ladder).
    function _mulmod(bytes memory a, bytes memory b) internal view returns (bytes memory o) {
        // Inline p + exp literals (via_ir: helper HOPs misroute at depth).
        bytes memory p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        // Inline schoolbook 512x512 (via_ir: the _mulWide hop misroutes
        // operand reads at depth — DbgL code 46 class). 16-bit limbs,
        // array-free; max half-word sum < 2^37.
        bytes memory prod = new bytes(128);
        uint256 carry = 0;
        for (uint256 k = 0; k < 64; k++) {
            uint256 sum = carry;
            for (uint256 i = 0; i < 32; i++) {
                if (i > k) break;
                uint256 j = k - i;
                if (j >= 32) continue;
                uint256 ao = 62 - 2 * i;
                uint256 bo = 62 - 2 * j;
                uint256 aw = (uint256(uint8(a[ao])) << 8) | uint256(uint8(a[ao + 1]));
                uint256 bw = (uint256(uint8(b[bo])) << 8) | uint256(uint8(b[bo + 1]));
                sum += aw * bw;
            }
            prod[126 - 2 * k] = bytes1(uint8((sum >> 8) & 0xFF));
            prod[127 - 2 * k] = bytes1(uint8(sum & 0xFF));
            carry = sum >> 16;
        }
        require(carry == 0, "mulcarry");
        // Modexp INLINE, fixed shape (base 128, exp 64, mod 48).
        // Length slots via _writeLen (inline literal stores above MISCODE
        // the value — DbgL BadPoint: 0x80/0x40/0x30 landed wrong).
        bytes memory input = new bytes(96 + 128 + 64 + 48);
        _writeLen(input, 0, 128);
        _writeLen(input, 32, 64);
        _writeLen(input, 64, 48);
        for (uint256 k = 0; k < 128; k++) input[96 + k] = prod[k];
        input[96 + 128 + 63] = bytes1(0x01);
        for (uint256 k = 0; k < 48; k++) input[96 + 128 + 64 + k] = p[k];
        (bool ok, bytes memory r) = address(0x05).staticcall(input);
        require(ok, "modexp");
        o = new bytes(64);
        for (uint256 k = 0; k < 48; k++) o[16 + k] = r[k];
    }

    /// @notice 512x512->1024 multiply (64B x 64B -> 128B) via 32-bit limbs.
    // Scratch carry slot for the array-free _mulWide (single uint256 in
    // a one-word memory array would reintroduce the bug class; instead the
    // carry ripples through a LOCAL across k — see loop below).
    function _mulWide(bytes memory a, bytes memory b, bytes memory prod) internal pure {
        // 16-bit limbs, 32 per operand (limb 0 = LEAST significant half-word).
        // acc-free schoolbook: for each output half-word k (0 = LSB), sum
        // aw[i]*bw[j] over i+j == k, plus the carry from position k-1.
        // Max sum: 32 products x (2^16-1)^2 + carry(<=2^21) < 2^37. Safe.
        uint256 carry = 0;
        for (uint256 k = 0; k < 64; k++) {
            uint256 sum = carry;
            for (uint256 i = 0; i < 32; i++) {
                if (i > k) break;
                uint256 j = k - i;
                if (j >= 32) continue;
                uint256 ao = 62 - 2 * i;
                uint256 bo = 62 - 2 * j;
                uint256 aw = (uint256(uint8(a[ao])) << 8) | uint256(uint8(a[ao + 1]));
                uint256 bw = (uint256(uint8(b[bo])) << 8) | uint256(uint8(b[bo + 1]));
                sum += aw * bw;
            }
            prod[126 - 2 * k] = bytes1(uint8((sum >> 8) & 0xFF));
            prod[127 - 2 * k] = bytes1(uint8(sum & 0xFF));
            carry = sum >> 16;
        }
        require(carry == 0, "mulcarry");
    }

    /// @notice (a+b) mod p, 64-byte buffers.
    function _addmod(bytes memory a, bytes memory b) internal view returns (bytes memory o) {
        // Inline 48-byte p literal (via_ir: the _pbe() HOP misroutes at depth).
        bytes memory p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        bytes memory sum = new bytes(65);
        uint256 carry = 0;
        for (uint256 k = 64; k > 0; k--) {
            uint256 t = uint256(uint8(a[k - 1])) + uint256(uint8(b[k - 1])) + carry;
            sum[k] = bytes1(uint8(t & 0xFF));
            carry = t >> 8;
        }
        sum[0] = bytes1(uint8(carry));
        bytes memory e1 = new bytes(64);
        e1[63] = bytes1(0x01);
        bytes memory sr = _modexpN(sum, 65, e1, 64, p, 48);
        o = new bytes(64);
        for (uint256 i = 0; i < 48; i++) o[16 + i] = sr[i];
    }

    /// @notice (p-a) mod p, 64-byte buffers.
    function _negMod(bytes memory a) internal pure returns (bytes memory o) {
        // Inline 64-byte p (via_ir: the _to64(_pbe()) HOP misroutes at depth).
        bytes memory p = hex"000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        // Inline zero test (via_ir: the _isZero64 HOP misroutes at depth).
        bool allZero = true;
        for (uint256 i = 0; i < 64; i++) {
            if (a[i] != bytes1(0)) {
                allZero = false;
                break;
            }
        }
        if (allZero) {
            o = new bytes(64);
            return o;
        }
        o = new bytes(64);
        uint256 borrow = 0;
        for (uint256 k = 64; k > 0; k--) {
            uint256 av = uint256(uint8(a[k - 1]));
            uint256 pv = uint256(uint8(p[k - 1]));
            if (pv >= borrow + av) {
                o[k - 1] = bytes1(uint8(pv - borrow - av));
                borrow = 0;
            } else {
                o[k - 1] = bytes1(uint8(256 + pv - borrow - av));
                borrow = 1;
            }
        }
    }

    /// @notice (a-b) mod p.
    function _submod(bytes memory a, bytes memory b) internal view returns (bytes memory o) {
        o = _addmod(a, _negMod(b));
    }

    /// @notice a^((p+3)/4) mod p, 64-byte result (modexp gives 48, left-pad).
    function _sqrtMod(bytes memory a) internal view returns (bytes memory o) {
        bytes memory p = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
        bytes memory e = hex"0680447a8e5ff9a692c6e9ed90d2eb35d91dd2e13ce144afd9cc34a83dac3d8907aaffffac54ffffee7fbfffffffeaab";
        // Modexp INLINE (via_ir: the _modexpN hop misroutes operand reads at
        // depth — DbgL code 46 class. Fixed shape: base 64, exp 48, mod 48).
        bytes memory input = new bytes(96 + 64 + 48 + 48);
        // lengths: base 64, exp 48, mod 48
        _writeLen(input, 0, 64);
        _writeLen(input, 32, 48);
        _writeLen(input, 64, 48);
        for (uint256 k = 0; k < 64; k++) input[96 + k] = a[k];
        for (uint256 k = 0; k < 48; k++) input[160 + k] = e[k];
        for (uint256 k = 0; k < 48; k++) input[208 + k] = p[k];
        (bool ok, bytes memory r) = address(0x05).staticcall(input);
        require(ok, "modexp");
        o = new bytes(64);
        for (uint256 k = 0; k < 48; k++) o[16 + k] = r[k];
    }

    /// @notice sort((2*y) div p): 1 iff 2*y >= p. y is a 64-byte buffer
    ///         whose TOP 16 bytes are zero (381-bit value); the comparison
    ///         must therefore run over the low 48 bytes only... but to keep
    ///         one code path, compare full 64 bytes against 64-byte (p+1)/2:
    ///         sort = 1 iff y >= (p+1)/2 (p odd: 2y>=p <=> y>=(p+1)/2).
    /// @dev The (p+1)/2 literal keeps its leading zero nibble (0d0088...):
    ///      2026-10-08 incident — stripping it to d0088... shifts the
    ///      comparison by 4 bits and flips the G1 sign for keys whose y
    ///      falls between the two thresholds (oracle K3). Pinned by
    ///      test_submitQC_ok (5-key QC) + DbgM leafHashes (per-key).
    function _sortBit(bytes memory y) internal pure returns (bool) {
        bytes memory half = _halfLit();
        for (uint256 i = 0; i < 64; i++) {
            uint8 yb = uint8(y[i]);
            uint8 hb = uint8(half[i]);
            if (yb > hb) return true;
            if (yb < hb) return false;
        }
        return true;
    }

    function _halfLit() internal pure returns (bytes memory h) {
        h = hex"000000000000000000000000000000000d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd556";
    }

    // ------------------------------------------------------------------ utils

    function _le64(bytes memory b, uint256 off) internal pure returns (uint64 v) {
        unchecked {
            for (uint256 i = 0; i < 8; i++) v |= uint64(uint8(b[off + i])) << (8 * i);
        }
    }

    function _le32(bytes memory b, uint256 off) internal pure returns (uint256 v) {
        unchecked {
            for (uint256 i = 0; i < 4; i++) v |= uint256(uint8(b[off + i])) << (8 * i);
        }
    }

    function _bytes32(bytes memory b, uint256 off) internal pure returns (bytes32 v) {
        unchecked {
            for (uint256 i = 0; i < 32; i++) v |= bytes32(bytes1(b[off + i])) >> (8 * i);
        }
    }

    function _bitSet(bytes memory mask, uint256 i) internal pure returns (bool) {
        uint256 byteIdx = i / 8;
        uint256 bitIdx = i % 8;
        return (uint8(mask[byteIdx]) & (uint8(0x80) >> uint8(bitIdx))) != 0;
    }

}
