import { describe, expect, it } from "vitest";
import { chipClass, whenText } from "./format";

describe("whenText and chipClass", () => {
  it.each([
    [0, "Today", "chip today"],
    [1, "Tomorrow", "chip soon"],
    [6, "in 6 days", "chip soon"],
    [7, "7 days", "chip soon"],
    [59, "59 days", "chip"],
    [60, "2 months", "chip"],
  ])("%d days is %s with class %s", (days, text, cls) => {
    expect(whenText(days)).toBe(text);
    expect(chipClass(days)).toBe(cls);
  });
});
