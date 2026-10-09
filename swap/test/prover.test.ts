/// Prover helper tests, pinned to the forge oracle vectors.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  fillLeafHash, foldInclusion, claimProvenArgs, parseLedgerInfo, sha3, ACC_TAG,
} from '../src/prover.ts';

const LEAF = '4bbc8b1ce34ad12463d6098cb21458a74c9ccafe70713faf70e8cc50103dde74';
const SIBS = [
  '7df9d8e4be294d24f9cafca7a098436b236cd2e000b5038125f05c68b4ca8c1f',
  'f6360c925e14e870b6ebf20a33881be054f3373f58dc2410f8115391f8d0f4e5',
  '872aae6980fa12b173be21b59105c6cccb4b2eb4d32e3b5a93b70be379c4ddc2',
];
const ROOT = 'b098d99b68e8de12fb60d62c31f50c52918d6badcf3f52e29e935f0f07e89654';
const RECIP = Buffer.from('aa'.repeat(32), 'hex');

describe('prover', () => {
  it('fill leaf matches the forge e2e vector', () => {
    assert.equal(fillLeafHash(0, RECIP, 1000000).toString('hex'), LEAF);
  });

  it('fold reaches the QC root', () => {
    const root = foldInclusion(
      Buffer.from(LEAF, 'hex'), 0,
      SIBS.map((s) => Buffer.from(s, 'hex')), sha3(ACC_TAG),
    );
    assert.equal(root.toString('hex'), ROOT);
  });

  it('claimProvenArgs builds + self-checks', () => {
    const args = claimProvenArgs(0, RECIP, 1000000, 0, SIBS, ROOT, '0xSolver');
    assert.equal(args.leafHash, '0x' + LEAF);
    assert.deepEqual(args.siblings.map((s) => s.replace(/^0x/, '')), SIBS);
  });

  it('claimProvenArgs rejects a wrong root', () => {
    assert.throws(() => claimProvenArgs(0, RECIP, 1000000, 0, SIBS, '00'.repeat(32), '0xSolver'));
  });

  it('parseLedgerInfo reads the e2e BCS', () => {
    const bcs = Buffer.from(
      '3a000000000000003279060000000000942b85fcb6352fde710118ff6bc38a5b00b6201bd45ed246262cfcb774d08a34b098d99b68e8de12fb60d62c31f50c52918d6badcf3f52e29e935f0f07e89654f883060000000000866761004e5d060000de6e8ba35fdd22c10cb70631065b3effe305ed4325e1a0dac96dc5b24ef5075a',
      'hex',
    );
    const li = parseLedgerInfo(bcs);
    assert.equal(li.epoch, 58n);
    assert.equal(li.version, 427000n);
    assert.equal(li.accRoot.toString('hex'), ROOT);
  });
});
