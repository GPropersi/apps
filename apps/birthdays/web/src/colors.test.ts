import { describe, expect, it } from "vitest";
import { initials, tintIndex } from "./colors";
import { loadVectors } from "./test-vectors";

describe("tintIndex (shared vectors)", () => {
  it.each(loadVectors().tintIndex)("$name -> $want", (v) => {
    expect(tintIndex(v.name)).toBe(v.want);
  });

  it("is stable and always in 0..5", () => {
    for (const name of ["", "x", "Sam Rivera", "a".repeat(500)]) {
      const n = tintIndex(name);
      expect(n).toBe(tintIndex(name));
      expect(n).toBeGreaterThanOrEqual(0);
      expect(n).toBeLessThan(6);
    }
  });
});

describe("initials", () => {
  it("uses the first letter of a single word", () => {
    expect(initials("ada")).toBe("A");
  });

  it("uses the first and last word", () => {
    expect(initials("Mary Jane Watson")).toBe("MW");
    expect(initials("  Sam   Rivera ")).toBe("SR");
  });

  it("handles non-Latin first letters", () => {
    expect(initials("日本語")).toBe("日");
    expect(initials("Élodie Žižek")).toBe("ÉŽ");
  });

  it("is code-point aware for astral letters", () => {
    expect(initials("\u{1D4D0}da")).toBe("\u{1D4D0}");
  });

  it("skips words with no letter and falls back for a name with none", () => {
    expect(initials("\u{1F600} Party")).toBe("P");
    expect(initials("1234")).toBe("\u{1F382}");
    expect(initials("\u{1F600}")).toBe("\u{1F382}");
  });
});
