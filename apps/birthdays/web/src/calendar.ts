// Calendar period maths and the date -> birthdays index. A period is a year, a month or a Sunday-Saturday week; dates
// are "YYYY-MM-DD" strings, so string comparison orders them. Feb 29 birthdays land on Feb 28 in common years through
// the shared `observedDay` rule in dates.ts.
import type { Birthday, CalendarZoom } from "./api";
import { MON, MONTHS, addDays, daysInMonth, formatDate, observedDay, parseDate, weekday } from "./dates";
import { compareNames } from "./format";

export type CalendarState = {
  // Any date inside the shown period (the period itself is derived from it and the zoom, so a zoom changed from
  // elsewhere, such as the Settings tab, can never leave the two disagreeing).
  shown: string;
  // The day the person picked in the month grid, or null.
  selected: string | null;
};

export function startOfPeriod(zoom: CalendarZoom, date: string): string {
  const { y, m } = parseDate(date);
  if (zoom === "year") {
    return formatDate(y, 1, 1);
  }
  if (zoom === "month") {
    return formatDate(y, m, 1);
  }
  return addDays(date, -weekday(date));
}

// The first date after the period that starts at `start`.
function endOfPeriod(zoom: CalendarZoom, start: string): string {
  const { y, m } = parseDate(start);
  if (zoom === "year") {
    return formatDate(y + 1, 1, 1);
  }
  if (zoom === "month") {
    return m === 12 ? formatDate(y + 1, 1, 1) : formatDate(y, m + 1, 1);
  }
  return addDays(start, 7);
}

export function inPeriod(zoom: CalendarZoom, shown: string, date: string): boolean {
  const start = startOfPeriod(zoom, shown);
  return date >= start && date < endOfPeriod(zoom, start);
}

// The start of the previous (dir -1) or next (dir 1) period.
export function shiftPeriod(zoom: CalendarZoom, shown: string, dir: 1 | -1): string {
  const start = startOfPeriod(zoom, shown);
  if (zoom === "week") {
    return addDays(start, 7 * dir);
  }
  const { y, m } = parseDate(start);
  if (zoom === "year") {
    return formatDate(y + dir, 1, 1);
  }
  const index = y * 12 + (m - 1) + dir;
  return formatDate(Math.floor(index / 12), (index % 12) + 1, 1);
}

// The one date every zoom change keeps: the selected day when it is in the shown period, else today when today is,
// else `shown` itself (the date the user arrived with, so Month -> Week -> Month never drifts to a neighbouring month).
export function anchorOf(zoom: CalendarZoom, shown: string, selected: string | null, today: string): string {
  if (selected !== null && inPeriod(zoom, shown, selected)) {
    return selected;
  }
  if (inPeriod(zoom, shown, today)) {
    return today;
  }
  return shown;
}

// The day highlighted in the month grid: the picked day when it is in the month, else today when it is.
export function effectiveSelection(shown: string, selected: string | null, today: string): string | null {
  return [selected, today].find((d): d is string => d !== null && inPeriod("month", shown, d)) ?? null;
}

export function periodLabel(zoom: CalendarZoom, shown: string): string {
  const start = startOfPeriod(zoom, shown);
  const s = parseDate(start);
  if (zoom === "year") {
    return String(s.y);
  }
  if (zoom === "month") {
    return `${MONTHS[s.m - 1]} ${s.y}`;
  }
  const e = parseDate(addDays(start, 6));
  const first = `${MON[s.m - 1]} ${s.d}`;
  const last = e.m === s.m ? String(e.d) : `${MON[e.m - 1]} ${e.d}`;
  return `${first} – ${last}, ${e.y}`;
}

export function monthDays(shown: string): string[] {
  const { y, m } = parseDate(startOfPeriod("month", shown));
  return Array.from({ length: daysInMonth(m, y) }, (_, i) => formatDate(y, m, i + 1));
}

// The month as Sunday-first week rows of 7 cells; null pads the days outside the month.
export function monthWeeks(monthStart: string): (string | null)[][] {
  const days = monthDays(monthStart);
  const cells: (string | null)[] = [...Array<null>(weekday(days[0] ?? monthStart)).fill(null), ...days];
  while (cells.length % 7 !== 0) {
    cells.push(null);
  }
  const rows: (string | null)[][] = [];
  for (let i = 0; i < cells.length; i += 7) {
    rows.push(cells.slice(i, i + 7));
  }
  return rows;
}

export type DayIndex = Map<string, Birthday[]>;

// Every birthday by the date it is observed on in each of `years`, names in order.
export function indexBirthdays(list: Birthday[], years: number[]): DayIndex {
  const index: DayIndex = new Map();
  for (const y of years) {
    for (const b of list) {
      const date = formatDate(y, b.month, observedDay(b.month, b.day, y));
      index.set(date, [...(index.get(date) ?? []), b]);
    }
  }
  for (const people of index.values()) {
    people.sort((a, b) => compareNames(a.name, b.name) || a.id - b.id);
  }
  return index;
}

// The years a period touches (a week can straddle New Year).
export function yearsOf(zoom: CalendarZoom, shown: string): number[] {
  const start = startOfPeriod(zoom, shown);
  const years = new Set([parseDate(start).y, parseDate(addDays(start, zoom === "week" ? 6 : 0)).y]);
  return Array.from(years);
}
