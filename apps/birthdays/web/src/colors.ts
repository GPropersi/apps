// Avatar helpers shared by every view, so the list, calendar and detail agree.

// h = h*31 + UTF-16 code unit, unsigned 32-bit; the tint is h % 6 (matches testdata/date-vectors.json).
export function tintIndex(name: string): number {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = (Math.imul(h, 31) + name.charCodeAt(i)) >>> 0;
  }
  return h % 6;
}

const FALLBACK_GLYPH = "\u{1F382}";

function firstLetter(word: string): string | null {
  for (const ch of Array.from(word)) {
    if (/\p{L}/u.test(ch)) {
      return ch.toLocaleUpperCase();
    }
  }
  return null;
}

// First letter of the first word plus first letter of the last word (code-point aware). Words with no letter are
// skipped; a name with no letters at all gets a fallback glyph.
export function initials(name: string): string {
  const words = name
    .split(/\s+/)
    .map(firstLetter)
    .filter((l): l is string => l !== null);
  if (words.length === 0) {
    return FALLBACK_GLYPH;
  }
  const first = words[0] ?? "";
  return words.length > 1 ? first + (words[words.length - 1] ?? "") : first;
}
