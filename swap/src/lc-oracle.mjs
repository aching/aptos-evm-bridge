/// AptosLightClient oracle: deterministic QC + inclusion vectors using
/// noble-curves BLS (POP DST, {DST} object form) over a synthetic committee.
/// Committee keys: sk_i = i (1..7), powers from live testnet proportions.
import { bls12_381 as bls } from '@noble/curves/bls12-381.js';
import { sha3_256 } from '@noble/hashes/sha3.js';
import { writeFileSync } from 'fs';

const POP = { DST: 'BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_' };
const hx = (b) => Buffer.from(b).toString('hex');
const LE64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b; };

// 1. Committee: sk 1..7, powers ~ live testnet (sum P, quorum = 2P/3+1).
const POWERS = [2100123443531745n, 2100123155682121n, 2100123063113211n, 2100123155334467n, 2100118789251558n, 2100122872964703n, 2100122871079190n];
const TOTAL = POWERS.reduce((a, b) => a + b, 0n);
const QUORUM = TOTAL * 2n / 3n + 1n;

// 2. Pubkeys: noble compressed (48B) + EIP uncompressed (128B).
const sks = [1n, 2n, 3n, 4n, 5n, 6n, 7n].map((s) => { const b = Buffer.alloc(32); b.writeBigUInt64BE(s, 24); return new Uint8Array(b); });
const pksComp = sks.map((sk) => Buffer.from(bls.getPublicKey(sk)));
function eipG1(comp48) {
  const P = bls.G1.ProjectivePoint.fromHex(comp48);
  const { x, y } = P.toAffine();
  const h = (x) => x.toString(16).padStart(96, '0');
  return '00000000000000000000000000000000' + h(x) + '00000000000000000000000000000000' + h(y);
}

// 3. LedgerInfo fields (BCS = BlockInfo ++ consensus_data_hash).
const EPOCH = 58n, ROUND = 424242n, VERSION = 427000n, TS = 1791439455479686n;
const BLOCK_ID = Buffer.from(sha3_256(Buffer.from('block-id-demo')));
const CDH = Buffer.from(sha3_256(Buffer.from('consensus-data-demo')));
const SEED = Buffer.from(sha3_256(Buffer.from('APTOS::LedgerInfo')));

// 4. Inclusion first: leaf + 3-level proof -> ROOT (ROOT goes into LI).
const ACC_SEED = Buffer.from(sha3_256(Buffer.from('APTOS::TransactionAccumulator')));
const LEAF = Buffer.from(sha3_256(Buffer.concat([Buffer.from('APTOS::TransactionInfo'), Buffer.from('fill-tx-demo-leaf')])));
const SIB0 = Buffer.from(sha3_256(Buffer.from('sibling-0')));
const SIB1 = Buffer.from(sha3_256(Buffer.from('sibling-1')));
const SIB2 = Buffer.from(sha3_256(Buffer.from('sibling-2')));
const accNode = (l, r) => Buffer.from(sha3_256(Buffer.concat([ACC_SEED, l, r])));
const L1 = accNode(LEAF, SIB0);
const L2 = accNode(L1, SIB1);
const ROOT = accNode(L2, SIB2);

const bcs = Buffer.concat([
  LE64(EPOCH), LE64(ROUND), BLOCK_ID,
  ROOT, LE64(VERSION), LE64(TS),
  Buffer.from([0]), CDH,
]);
const MSG = Buffer.concat([SEED, bcs]);

// 5. Signers: indices [0..4]; check power >= quorum.
const SIGNERS = [0, 1, 2, 3, 4];
const sp = SIGNERS.reduce((a, i) => a + POWERS[i], 0n);
console.error('signer power:', sp.toString(), 'quorum:', QUORUM.toString(), 'ok:', sp >= QUORUM);
const sigs = SIGNERS.map((i) => bls.sign(MSG, sks[i], POP));
const aggSigComp = Buffer.from(bls.aggregateSignatures(sigs));
function eipG2(comp96) {
  const P = bls.G2.ProjectivePoint.fromHex(comp96);
  const { x, y } = P.toAffine();
  const h = (x) => x.toString(16).padStart(96, '0');
  return '00000000000000000000000000000000' + h(x.c0) + '00000000000000000000000000000000' + h(x.c1)
       + '00000000000000000000000000000000' + h(y.c0) + '00000000000000000000000000000000' + h(y.c1);
}
const aggPk = bls.aggregatePublicKeys(SIGNERS.map((i) => pksComp[i]));
console.error('noble agg verify:', bls.verify(aggSigComp, MSG, aggPk, POP));

const out = {
  powers: POWERS.map(String),
  totalPower: TOTAL.toString(), quorumPower: QUORUM.toString(),
  pubkeysCompressed: pksComp.map((b) => b.toString('hex')),
  pubkeysEIP: pksComp.map((b) => eipG1(b)),
  epoch: Number(EPOCH), round: Number(ROUND), version: Number(VERSION), timestampUsecs: TS.toString(),
  blockId: BLOCK_ID.toString('hex'), consensusDataHash: CDH.toString('hex'),
  accRoot: ROOT.toString('hex'),
  bcsLedgerInfo: bcs.toString('hex'),
  signers: SIGNERS,
  bitmask: 'f8',
  aggSigCompressed: aggSigComp.toString('hex'),
  aggSigEIP: eipG2(aggSigComp),
  leafIndex: 0, leafHash: LEAF.toString('hex'),
  siblings: [SIB0.toString('hex'), SIB1.toString('hex'), SIB2.toString('hex')],
  fillRecipient: 'aa'.repeat(32), fillAmountOctas: '1000000',
};
writeFileSync('/tmp/lc-vec.json', JSON.stringify(out, null, 1));
console.error('wrote /tmp/lc-vec.json');
