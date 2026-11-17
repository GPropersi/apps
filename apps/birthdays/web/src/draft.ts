// The Add draft: app-level state mirrored to sessionStorage (same tab only; names and dates, never secrets), tagged
// with the signed-in lowercased email and restored only for that same person. Storage can throw (private windows,
// blocked site data), so every access is wrapped and the app works without it.

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

export function saveDraft(email: string, d: Draft): void {
  try {
    if (isEmptyDraft(d)) {
      window.sessionStorage.removeItem(KEY);
    } else {
      window.sessionStorage.setItem(KEY, JSON.stringify({ ...d, email: email.toLowerCase() }));
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

// The stored draft when it belongs to `email`; any other person's draft is discarded.
export function loadDraft(email: string): Draft | null {
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
    if (r.email !== email.toLowerCase()) {
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
// lowercased email (same rules as the Add draft: same tab only, names and dates only, discarded for another person).
export type EditDraft = { name: string; month: number; day: string; year: string };

const EDIT_PREFIX = "birthdays:edit-draft:";

export function saveEditDraft(email: string, id: number, d: EditDraft): void {
  try {
    window.sessionStorage.setItem(EDIT_PREFIX + id, JSON.stringify({ ...d, email: email.toLowerCase() }));
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

export function loadEditDraft(email: string, id: number): EditDraft | null {
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
      r.email !== email.toLowerCase() ||
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
