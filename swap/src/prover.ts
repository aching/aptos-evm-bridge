/// Proven-fill prover helpers: build claimProven args from an Aptos fill.
/// Leaf convention (must match SwapEscrow.claimProven docs + oracle):
///   leafPreimage = LE64(swapId) || recipient32 || LE64(amountOctas)
///   leafHash = SHA3-256("APTOS::TransactionInfo" || leafPreimage)
/// Accumulator fold: node = SHA3-256(accSeed || left || right),
///   accSeed = SHA3-256("APTOS::TransactionAccumulator"),
///   even index = left child. Matches AptosLightClient.fold1/verifyInclusion.
import { sha3_256 } from '@noble/hashes/sha3.js';

export const TX_INFO_TAG = Buffer.from('APTOS::TransactionInfo');
export const ACC_TAG = Buffer.from('APTOS::TransactionAccumulator');

export function sha3(b: Buffer): Buffer {
  return Buffer.from(sha3_256(b));
}

export function le64(n: bigint | number): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n));
  return b;
}

/** Fill leaf preimage: swapId || 32-byte Aptos recipient || amount. */
export function fillPreimage(swapId: bigint | number, recipient32: Buffer, amountOctas: bigint | number): Buffer {
  if (recipient32.length !== 32) throw new Error('recipient must be 32 bytes');
  return Buffer.concat([le64(swapId), recipient32, le64(amountOctas)]);
}

/** TransactionInfo-hash standin for the fill leaf. */
export function fillLeafHash(swapId: bigint | number, recipient32: Buffer, amountOctas: bigint | number): Buffer {
  return sha3(Buffer.concat([TX_INFO_TAG, fillPreimage(swapId, recipient32, amountOctas)]));
}

/** One accumulator node. */
export function accNode(accSeed: Buffer, left: Buffer, right: Buffer): Buffer {
  return sha3(Buffer.concat([accSeed, left, right]));
}

/** Fold a leaf through siblings bottom-up (even index = left child). */
export function foldInclusion(
  leaf: Buffer,
  leafIndex: bigint | number,
  siblings: Buffer[],
  accSeed: Buffer = sha3(ACC_TAG),
): Buffer {
  let h = leaf;
  let idx = BigInt(leafIndex);
  for (const sib of siblings) {
    h = idx % 2n === 0n ? accNode(accSeed, h, sib) : accNode(accSeed, sib, h);
    idx /= 2n;
  }
  return h;
}

/** Build claimProven args, asserting the fold reaches the QC root. */
export function claimProvenArgs(
  swapId: bigint | number,
  recipient32: Buffer,
  amountOctas: bigint | number,
  leafIndex: bigint | number,
  siblingsHex: string[],
  expectedRootHex: string,
  payoutSolver: string,
): { leafHash: string; leafIndex: string; siblings: string[]; payoutSolver: string } {
  const leaf = fillLeafHash(swapId, recipient32, amountOctas);
  const sibs = siblingsHex.map((s) => Buffer.from(s.replace(/^0x/, ''), 'hex'));
  const root = foldInclusion(leaf, leafIndex, sibs);
  const want = expectedRootHex.replace(/^0x/, '').toLowerCase();
  if (root.toString('hex') !== want) {
    throw new Error(`inclusion fold ${root.toString('hex')} != QC root ${want}`);
  }
  return {
    leafHash: '0x' + leaf.toString('hex'),
    leafIndex: BigInt(leafIndex).toString(),
    siblings: sibs.map((s) => '0x' + s.toString('hex')),
    payoutSolver,
  };
}

/** Parse a 129-byte no-rotation LedgerInfo BCS (mirrors the on-chain layout). */
export function parseLedgerInfo(bcs: Buffer): {
  epoch: bigint; round: bigint; blockId: Buffer; accRoot: Buffer;
  version: bigint; timestampUsecs: bigint; consensusDataHash: Buffer;
} {
  if (bcs.length !== 129) throw new Error(`bad BCS length ${bcs.length}`);
  if (bcs[96] !== 0) throw new Error('has next-epoch-state');
  return {
    epoch: bcs.readBigUInt64LE(0),
    round: bcs.readBigUInt64LE(8),
    blockId: bcs.subarray(16, 48),
    accRoot: bcs.subarray(48, 80),
    version: bcs.readBigUInt64LE(80),
    timestampUsecs: bcs.readBigUInt64LE(88),
    consensusDataHash: bcs.subarray(97, 129),
  };
}
