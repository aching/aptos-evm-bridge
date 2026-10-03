/// Persistent relayer state (JSON file, atomic writes).
/// Survives restarts: last scanned Maroo block, attested nonces (forward),
/// processed withdraw nonces (back), per-leg idempotency records, history.
import fs from "node:fs";
import path from "node:path";

export interface LegRecord {
  key: string; // idempotency key
  status: "submitted" | "confirmed" | "failed";
  marooTx?: string;
  aptosTx?: string;
  detail: string;
  updatedAt: string;
}

export interface HistEntry {
  time: string;
  step: string;
  detail: string;
  marooTx?: string;
  aptosTx?: string;
}

interface StoreShape {
  lastBlock: string | null; // Maroo head cursor (forward watcher)
  seenForward: string[]; // attested maroo nonces
  seenBack: string[]; // processed withdraw nonces (aptos -> maroo)
  legs: Record<string, LegRecord>; // idempotency ledger
  history: HistEntry[];
}

const DEFAULTS: StoreShape = {
  lastBlock: null,
  seenForward: [],
  seenBack: [],
  legs: {},
  history: [],
};

export class Store {
  private file: string;
  private s: StoreShape;

  constructor(dir: string) {
    fs.mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, "relayer-state.json");
    try {
      const raw = fs.readFileSync(this.file, "utf8");
      this.s = { ...DEFAULTS, ...JSON.parse(raw) };
    } catch {
      this.s = { ...DEFAULTS };
      this.save();
    }
  }

  private save() {
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.s, null, 1));
    fs.renameSync(tmp, this.file);
  }

  // -- forward cursor
  get lastBlock(): bigint | null {
    return this.s.lastBlock === null ? null : BigInt(this.s.lastBlock);
  }
  set lastBlock(b: bigint) {
    this.s.lastBlock = b.toString();
    this.save();
  }

  // -- nonce sets
  hasForward(nonce: string): boolean {
    return this.s.seenForward.includes(nonce);
  }
  addForward(nonce: string) {
    if (!this.hasForward(nonce)) {
      this.s.seenForward.push(nonce);
      this.save();
    }
  }
  hasBack(nonce: string): boolean {
    return this.s.seenBack.includes(nonce);
  }
  addBack(nonce: string) {
    if (!this.hasBack(nonce)) {
      this.s.seenBack.push(nonce);
      this.save();
    }
  }

  // -- idempotency ledger
  getLeg(key: string): LegRecord | undefined {
    return this.s.legs[key];
  }
  putLeg(rec: Omit<LegRecord, "updatedAt">) {
    this.s.legs[rec.key] = { ...rec, updatedAt: new Date().toISOString() };
    // cap ledger at 200 entries (demo scale)
    const keys = Object.keys(this.s.legs);
    if (keys.length > 200) delete this.s.legs[keys[0]];
    this.save();
  }

  // -- history (persisted, capped at 100)
  log(step: string, detail: string, links: { marooTx?: string; aptosTx?: string } = {}) {
    this.s.history.unshift({ time: new Date().toISOString(), step, detail, ...links });
    if (this.s.history.length > 100) this.s.history.length = 100;
    this.save();
    console.log(`[web] ${step}: ${detail}`);
  }
  get history(): HistEntry[] {
    return this.s.history;
  }
}
