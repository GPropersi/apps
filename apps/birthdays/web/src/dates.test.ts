import { describe, expect, it } from "vitest";
import { addDays, daysUntil, longDate, occurrence, todayISO, turning, validDate, weekday } from "./dates";
import { loadVectors } from "./test-vectors";

const vectors = loadVectors();

describe("shared date vectors (the same file internal/app/dates_test.go reads)", () => {
  it.each(vectors.occurrence)("occurrence of $month/$day from $from is $want", (v) => {
    expect(occurrence(v.month, v.day, v.from)).toBe(v.want);
  });

  it.each(vectors.daysUntil)("daysUntil $from to $to is $want", (v) => {
    expect(daysUntil(v.from, v.to)).toBe(v.want);
  });

  it.each(vectors.turning)("turning year $year at $occurrence is $want", (v) => {
    expect(turning(v.year, v.occurrence)).toBe(v.want);
  });

  it.each(vectors.validDate)("validDate $month/$day/$year is $want", (v) => {
    expect(validDate(v.month, v.day, v.year)).toBe(v.want);
  });
});

describe("date helpers", () => {
  it("formats the local calendar date", () => {
    expect(todayISO(new Date(2026, 10, 16, 23, 59))).toBe("2026-11-16");
  });

  it("adds days across a month and year boundary", () => {
    expect(addDays("2026-12-30", 3)).toBe("2027-01-02");
    expect(addDays("2028-02-28", 1)).toBe("2028-02-29");
  });

  it("knows the weekday (0 = Sunday)", () => {
    expect(weekday("2026-11-15")).toBe(0);
    expect(weekday("2026-11-21")).toBe(6);
  });

  it("formats a long date with the year from the one date", () => {
    expect(longDate("2026-11-27")).toBe("Friday, November 27, 2026");
    expect(longDate("2027-11-27")).toBe("Saturday, November 27, 2027");
    expect(longDate("2027-03-05")).toBe("Friday, March 5, 2027");
    expect(longDate("2027-02-28")).toBe("Sunday, February 28, 2027");
  });
});
