import { describe, expect, it } from "vitest";
import css from "./styles.css?raw";

type Tokens = Record<string, string>;

// Reads every `selector { --token: value; ... }` rule, including those inside @media, into selector -> tokens.
function parseRules(source: string): Map<string, Tokens> {
  const rules = new Map<string, Tokens>();
  const stripped = source.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const m of stripped.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selector = (m[1] ?? "").trim();
    const tokens: Tokens = {};
    for (const d of (m[2] ?? "").matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
      tokens[d[1] ?? ""] = (d[2] ?? "").trim();
    }
    if (Object.keys(tokens).length > 0) {
      rules.set(selector, { ...(rules.get(selector) ?? {}), ...tokens });
    }
  }
  return rules;
}

const rules = parseRules(css);
const SCHEMES = ["confetti", "frosting", "candle"] as const;

function rule(selector: string): Tokens {
  return rules.get(selector) ?? {};
}

function lightTokens(scheme: string): Tokens {
  return { ...rule(":root"), ...(scheme === "confetti" ? {} : rule(`:root[data-palette=${scheme}]`)) };
}

function darkTokens(scheme: string): Tokens {
  return {
    ...lightTokens(scheme),
    ...rule(":root:not([data-theme=light])"),
    ...(scheme === "confetti" ? {} : rule(`:root[data-palette=${scheme}]:not([data-theme=light])`)),
  };
}

function forcedDarkTokens(scheme: string): Tokens {
  return {
    ...lightTokens(scheme),
    ...rule(":root[data-theme=dark]"),
    ...(scheme === "confetti" ? {} : rule(`:root[data-palette=${scheme}][data-theme=dark]`)),
  };
}

function channel(v: number): number {
  const c = v / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function luminance(hex: string): number {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => channel(parseInt(h.slice(i, i + 2), 16)));
  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
}

function ratio(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return ((hi ?? 0) + 0.05) / ((lo ?? 0) + 0.05);
}

// [foreground token, background token, minimum ratio]: 4.5 for text, 3 for large text and UI parts.
const PAIRS: [string, string, number][] = [
  ["--text", "--bg", 4.5],
  ["--text", "--surface", 4.5],
  ["--text", "--surface-2", 4.5],
  ["--text", "--accent-soft", 4.5], // hero eyebrow and meta, soon chip, banner, current tab
  ["--text", "--t0", 4.5], // avatar initials on every tint
  ["--text", "--t1", 4.5],
  ["--text", "--t2", 4.5],
  ["--text", "--t3", 4.5],
  ["--text", "--t4", 4.5],
  ["--text", "--t5", 4.5],
  ["--muted", "--bg", 4.5],
  ["--muted", "--surface", 4.5],
  ["--muted", "--surface-2", 4.5],
  ["--accent-text", "--accent", 4.5], // primary button, chosen month
  ["--highlight-text", "--highlight", 4.5], // Today chip, today's circle
  ["--accent", "--surface", 4.5], // group headings, active tab label
  ["--accent", "--bg", 4.5],
  ["--accent", "--accent-soft", 4.5], // active tab label on its pill
  ["--error", "--surface", 4.5],
  ["--error", "--bg", 4.5],
  ["--error", "--surface-2", 4.5],
  ["--ok", "--surface", 4.5],
  ["--focus", "--bg", 3],
  ["--focus", "--surface", 3],
  ["--accent", "--surface-2", 3], // focus ring on an input
];

describe("styles.css colour tokens", () => {
  it("defines every documented token for every scheme and mode", () => {
    const needed = new Set(PAIRS.flat().filter((x): x is string => typeof x === "string" && x.startsWith("--")));
    for (const scheme of SCHEMES) {
      for (const tokens of [lightTokens(scheme), darkTokens(scheme)]) {
        for (const t of needed) {
          expect(tokens[t], `${scheme} ${t}`).toMatch(/^#[0-9a-f]{6}$/i);
        }
        for (const extra of ["--shadow", "--font-body", "--font-display", "--display-weight"]) {
          expect(tokens[extra], `${scheme} ${extra}`).toBeTruthy();
        }
      }
    }
  });

  it.each(SCHEMES.flatMap((s) => [`${s} light`, `${s} dark`]))("meets WCAG AA for every pair: %s", (label) => {
    const [scheme, mode] = label.split(" ") as [string, string];
    const tokens = mode === "dark" ? darkTokens(scheme) : lightTokens(scheme);
    const failing: string[] = [];
    for (const [fg, bg, min] of PAIRS) {
      const r = ratio(tokens[fg] ?? "", tokens[bg] ?? "");
      if (!(r >= min)) {
        failing.push(`${fg} on ${bg} is ${r.toFixed(2)} (needs ${min})`);
      }
    }
    expect(failing, label).toEqual([]);
  });

  it("keeps the forced data-theme=dark blocks identical to the media-query dark blocks", () => {
    for (const scheme of SCHEMES) {
      expect(forcedDarkTokens(scheme), scheme).toEqual(darkTokens(scheme));
    }
  });

  it("leaves Confetti on bare :root and declares color-scheme: light dark", () => {
    expect(css).toMatch(/:root\s*\{\s*color-scheme:\s*light dark;/);
    expect(rule(":root")["--accent"]).toBeTruthy();
    expect(css).not.toMatch(/data-palette=confetti\]\s*\{/);
  });

  it("does not depend on :has() for selected or focus state (older iOS)", () => {
    expect(css).not.toContain(":has(");
  });

  it("names no external font URL", () => {
    expect(css).not.toMatch(/https?:\/\//);
  });
});
