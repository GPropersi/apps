import { describe, expect, it } from "vitest";
import type { Birthday } from "./api";
import {
  anchorOf,
  effectiveSelection,
  inPeriod,
  indexBirthdays,
  monthDays,
  monthWeeks,
  periodLabel,
  shiftPeriod,
  startOfPeriod,
  yearsOf,
} from "./calendar";

function bd(id: number, name: string, month: number, day: number): Birthday {
  return { id, name, month, day, year: null, is_mine: true, owner_email: "a@example.com", reminder_offsets: [] };
}

describe("period maths", () => {
  it("finds the start of each period (weeks start on Sunday)", () => {
    expect(startOfPeriod("year", "2026-11-16")).toBe("2026-01-01");
    expect(startOfPeriod("month", "2026-11-16")).toBe("2026-11-01");
    expect(startOfPeriod("week", "2026-11-16")).toBe("2026-11-15");
    expect(startOfPeriod("week", "2026-11-15")).toBe("2026-11-15");
    expect(startOfPeriod("week", "2027-01-01")).toBe("2026-12-27");
  });

  it("shifts by one period across month and year ends", () => {
    expect(shiftPeriod("month", "2026-12-10", 1)).toBe("2027-01-01");
    expect(shiftPeriod("month", "2026-01-10", -1)).toBe("2025-12-01");
    expect(shiftPeriod("year", "2026-06-06", 1)).toBe("2027-01-01");
    expect(shiftPeriod("week", "2026-11-16", 1)).toBe("2026-11-22");
    expect(shiftPeriod("week", "2026-11-16", -1)).toBe("2026-11-08");
  });

  it("labels each zoom, naming both months when a week crosses a month end", () => {
    expect(periodLabel("year", "2026-11-16")).toBe("2026");
    expect(periodLabel("month", "2026-11-16")).toBe("November 2026");
    expect(periodLabel("week", "2026-11-16")).toBe("Nov 15 – 21, 2026");
    expect(periodLabel("week", "2026-11-30")).toBe("Nov 29 – Dec 5, 2026");
  });

  it("handles week and leap-day edges", () => {
    expect(shiftPeriod("week", "2026-12-30", 1)).toBe("2027-01-03");
    expect(shiftPeriod("week", "2027-01-01", -1)).toBe("2026-12-20");
    expect(startOfPeriod("week", "2028-02-29")).toBe("2028-02-27");
    expect(inPeriod("month", "2028-02-10", "2028-02-29")).toBe(true);
    expect(inPeriod("month", "2028-02-10", "2028-03-01")).toBe(false);
    expect(inPeriod("week", "2028-02-27", "2028-02-29")).toBe(true);
  });

  it("builds Sunday-first week rows for a month", () => {
    const nov = monthWeeks("2026-11-16");
    expect(nov).toHaveLength(5);
    expect(nov[0]?.[0]).toBe("2026-11-01");
    expect(nov.every((r) => r.length === 7)).toBe(true);
    expect(nov[4]?.slice(-5)).toEqual([null, null, null, null, null]);
    // Feb 2026 starts on a Sunday and has 28 days: exactly 4 full rows (Feb 2027 starts Monday, so it needs 5).
    const feb = monthWeeks("2026-02-10");
    expect(feb).toHaveLength(4);
    expect(feb[0]?.[0]).toBe("2026-02-01");
    expect(feb[3]?.[6]).toBe("2026-02-28");
    expect(monthWeeks("2027-02-10")).toHaveLength(5);
    expect(monthWeeks("2026-08-01")[0]?.slice(0, 6)).toEqual([null, null, null, null, null, null]);
  });

  it("lists the days of a month (28 and 29 in February)", () => {
    expect(monthDays("2026-11-16")).toHaveLength(30);
    expect(monthDays("2027-02-10")).toHaveLength(28);
    expect(monthDays("2028-02-10")).toHaveLength(29);
  });

  it("knows which years a week touches", () => {
    expect(yearsOf("week", "2026-12-30")).toEqual([2026, 2027]);
    expect(yearsOf("month", "2026-12-30")).toEqual([2026]);
  });

  it("checks period membership", () => {
    expect(inPeriod("week", "2026-11-16", "2026-11-21")).toBe(true);
    expect(inPeriod("week", "2026-11-16", "2026-11-22")).toBe(false);
    expect(inPeriod("month", "2026-11-16", "2026-12-01")).toBe(false);
  });
});

describe("anchor rule", () => {
  it("keeps the date the user arrived with when neither a selection nor today is in the period", () => {
    // Month -> Week -> Month in December: the week's first day (Nov 29) must not become the anchor.
    expect(anchorOf("week", "2026-12-01", null, "2026-11-16")).toBe("2026-12-01");
    expect(anchorOf("month", "2026-12-01", null, "2026-11-16")).toBe("2026-12-01");
  });

  it("prefers the selected day, then today, then the shown date", () => {
    expect(anchorOf("month", "2026-11-01", "2026-11-03", "2026-11-16")).toBe("2026-11-03");
    expect(anchorOf("month", "2026-11-01", null, "2026-11-16")).toBe("2026-11-16");
    expect(anchorOf("month", "2026-12-01", null, "2026-11-16")).toBe("2026-12-01");
    expect(anchorOf("month", "2026-12-01", "2026-11-03", "2026-11-16")).toBe("2026-12-01");
  });

  it("highlights the picked day, else today, only inside the month", () => {
    expect(effectiveSelection("2026-11-01", "2026-11-03", "2026-11-16")).toBe("2026-11-03");
    expect(effectiveSelection("2026-11-01", null, "2026-11-16")).toBe("2026-11-16");
    expect(effectiveSelection("2026-12-01", "2026-11-03", "2026-11-16")).toBeNull();
  });
});

describe("indexBirthdays", () => {
  it("puts a Feb 29 birthday on Feb 28 in a common year and on Feb 29 in a leap year", () => {
    const leap = bd(1, "Leap", 2, 29);
    expect(indexBirthdays([leap], [2027]).get("2027-02-28")).toEqual([leap]);
    expect(indexBirthdays([leap], [2027]).has("2027-03-01")).toBe(false);
    expect(indexBirthdays([leap], [2028]).get("2028-02-29")).toEqual([leap]);
  });

  it("orders the people on a day by name", () => {
    const z = bd(1, "Zed", 5, 5);
    const a = bd(2, "Ada", 5, 5);
    expect(indexBirthdays([z, a], [2026]).get("2026-05-05")).toEqual([a, z]);
  });
});
