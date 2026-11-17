import { describe, expect, it } from "vitest";
import { chipClass, timingLabel, whenText } from "./format";

describe("timingLabel", () => {
  it.each([
    [[7], "1 week before"],
    [[1], "1 day before"],
    [[0], "on the day"],
    [[7, 1], "1 week and 1 day before"],
    [[7, 0], "1 week before and on the day"],
    [[1, 0], "1 day before and on the day"],
    [[7, 1, 0], "1 week and 1 day before and on the day"],
    [[0, 1, 7], "1 week and 1 day before and on the day"],
    [[1, 7], "1 week and 1 day before"],
  ])("offsets %j read %s", (offsets, want) => {
    expect(timingLabel(offsets)).toBe(want);
  });
});

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
