// The Add draft: app-level state mirrored to sessionStorage (same tab only; names and dates, never secrets), tagged
// with the signed-in person's tag (draftTag: a SHA-256 of the lowercased email, never the email itself) and restored
// only for that same person. Storage can throw (private windows, blocked site data), so every access is wrapped and
// the app works without it.

const PRIMES: number[] = [];
for (let n = 2; PRIMES.length < 64; n++) {
  if (PRIMES.every((p) => n % p !== 0)) {
    PRIMES.push(n);
  }
}
// FIPS 180-4: the round constants are the first 32 bits of the fractional parts of the cube roots of the first 64
// primes, the initial hash is the same for the square roots of the first 8.
const frac32 = (x: number): number => Math.floor((x - Math.floor(x)) * 2 ** 32);
const ROUND_K = PRIMES.map((p) => frac32(Math.cbrt(p)));
const INITIAL_H = PRIMES.slice(0, 8).map((p) => frac32(Math.sqrt(p)));
const rotr = (x: number, n: number): number => (x >>> n) | (x << (32 - n));

// SHA-256 as lowercase hex. Synchronous on purpose (WebCrypto is async and absent from some test environments), and
// checked against the standard test vectors in draft.test.ts.
export function sha256Hex(text: string): string {
  const data = new TextEncoder().encode(text);
  const bits = data.length * 8;
  const padded = new Uint8Array(((data.length + 9 + 63) >> 6) << 6);
  padded.set(data);
  padded[data.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(bits / 2 ** 32));
  view.setUint32(padded.length - 4, bits >>> 0);
  const h = [...INITIAL_H];
  const w = new Array<number>(64).fill(0);
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(off + i * 4);
    }
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let [a, b, c, d, e, f, g, k] = h;
    for (let i = 0; i < 64; i++) {
      const t1 = (k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + ROUND_K[i] + w[i]) | 0;
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
      k = g;
      g = f;
      f = e;
      e = (d + t1) | 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) | 0;
    }
    [a, b, c, d, e, f, g, k].forEach((x, i) => {
      h[i] = (h[i] + x) | 0;
    });
  }
  return h.map((x) => (x >>> 0).toString(16).padStart(8, "0")).join("");
}

// The tag a draft is stored under for this signed-in person: it lets a restore tell "same person" from "someone else"
// without the email itself ever reaching storage.
export function draftTag(email: string): string {
  return sha256Hex(email.toLowerCase());
}

export type Draft = {
  name: string;
  month: number; // 0 = none picked
  day: string;
  year: string;
  remind: boolean | null; // null = untouched: follows the person's auto_remind
};

export const EMPTY_DRAFT: Draft = { name: "", month: 0, day: "", year: "", remind: null };

const KEY = "birthdays:add-draft";

export function isEmptyDraft(d: Draft): boolean {
  return d.name === "" && d.month === 0 && d.day === "" && d.year === "" && d.remind === null;
}

export function saveDraft(tag: string, d: Draft): void {
  try {
    if (isEmptyDraft(d)) {
      window.sessionStorage.removeItem(KEY);
    } else {
      window.sessionStorage.setItem(KEY, JSON.stringify({ ...d, who: tag }));
    }
  } catch {
    // storage unavailable: the draft just lives in memory
  }
}

export function clearDraft(): void {
  try {
    window.sessionStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}

// The stored draft when it belongs to `tag`; any other person's draft is discarded.
export function loadDraft(tag: string): Draft | null {
  try {
    const raw = window.sessionStorage.getItem(KEY);
    if (raw === null) {
      return null;
    }
    const v: unknown = JSON.parse(raw);
    if (typeof v !== "object" || v === null) {
      clearDraft();
      return null;
    }
    const r = v as Record<string, unknown>;
    if (r.who !== tag) {
      clearDraft();
      return null;
    }
    if (
      typeof r.name !== "string" ||
      typeof r.month !== "number" ||
      typeof r.day !== "string" ||
      typeof r.year !== "string" ||
      (r.remind !== null && typeof r.remind !== "boolean")
    ) {
      clearDraft();
      return null;
    }
    return { name: r.name, month: r.month, day: r.day, year: r.year, remind: r.remind };
  } catch {
    return null;
  }
}

// The owner's detail edit draft: one per birthday id, app-level state mirrored to sessionStorage with the signed-in
// person tag (same rules as the Add draft: same tab only, names and dates only, discarded for another person).
export type EditDraft = { name: string; month: number; day: string; year: string };

const EDIT_PREFIX = "birthdays:edit-draft:";

export function saveEditDraft(tag: string, id: number, d: EditDraft): void {
  try {
    window.sessionStorage.setItem(EDIT_PREFIX + id, JSON.stringify({ ...d, who: tag }));
  } catch {
    // storage unavailable: the draft just lives in memory
  }
}

export function clearEditDraft(id: number): void {
  try {
    window.sessionStorage.removeItem(EDIT_PREFIX + id);
  } catch {
    // ignore
  }
}

export function loadEditDraft(tag: string, id: number): EditDraft | null {
  try {
    const raw = window.sessionStorage.getItem(EDIT_PREFIX + id);
    if (raw === null) {
      return null;
    }
    const v: unknown = JSON.parse(raw);
    if (typeof v !== "object" || v === null) {
      clearEditDraft(id);
      return null;
    }
    const r = v as Record<string, unknown>;
    if (
      r.who !== tag ||
      typeof r.name !== "string" ||
      typeof r.month !== "number" ||
      typeof r.day !== "string" ||
      typeof r.year !== "string"
    ) {
      clearEditDraft(id);
      return null;
    }
    return { name: r.name, month: r.month, day: r.day, year: r.year };
  } catch {
    return null;
  }
}
