// Civil-date helpers. A date is "YYYY-MM-DD" (zero padded, so string comparison orders dates). The rules mirror
// internal/app/dates.go and are checked against the shared fixture testdata/date-vectors.json: a Feb 29 birthday is
// observed on Feb 28 in common years.

export const MONTHS = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
] as const;
export const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;
export const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
export const WDL = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] as const;

const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
const MS_PER_DAY = 86_400_000;

export function isLeap(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

// Days in a month (1-12); a missing year counts February as 29 days (a Feb 29 birthday is allowed without a year).
export function daysInMonth(month: number, year: number | null): number {
  if (month === 2) {
    return year === null || isLeap(year) ? 29 : 28;
  }
  return DAYS_IN_MONTH[month - 1] ?? 0;
}

export function validDate(month: number, day: number, year: number | null): boolean {
  if (!Number.isInteger(month) || !Number.isInteger(day) || month < 1 || month > 12 || day < 1) {
    return false;
  }
  if (year !== null && (!Number.isInteger(year) || year < 1900 || year > 2200)) {
    return false;
  }
  return day <= daysInMonth(month, year);
}

function pad(n: number, width: number): string {
  return String(n).padStart(width, "0");
}

export function formatDate(y: number, m: number, d: number): string {
  return `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}`;
}

export function parseDate(s: string): { y: number; m: number; d: number } {
  return { y: Number(s.slice(0, 4)), m: Number(s.slice(5, 7)), d: Number(s.slice(8, 10)) };
}

// The device-local calendar date.
export function todayISO(now: Date = new Date()): string {
  return formatDate(now.getFullYear(), now.getMonth() + 1, now.getDate());
}

function dayNumber(s: string): number {
  const { y, m, d } = parseDate(s);
  return Math.round(Date.UTC(y, m - 1, d) / MS_PER_DAY);
}

export function daysUntil(from: string, to: string): number {
  return dayNumber(to) - dayNumber(from);
}

export function addDays(s: string, n: number): string {
  const { y, m, d } = parseDate(s);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return formatDate(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}

// 0 = Sunday.
export function weekday(s: string): number {
  const { y, m, d } = parseDate(s);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

// The day a birthday is observed in a year: Feb 29 falls on Feb 28 in a common year.
export function observedDay(month: number, day: number, year: number): number {
  return month === 2 && day === 29 && !isLeap(year) ? 28 : day;
}

// The first observed date on or after `from`.
export function occurrence(month: number, day: number, from: string): string {
  const fromYear = parseDate(from).y;
  for (let y = fromYear; ; y++) {
    const candidate = formatDate(y, month, observedDay(month, day, y));
    if (candidate >= from) {
      return candidate;
    }
  }
}

// The age reached on `occ`, or null with no (or a not yet reached) birth year.
export function turning(year: number | null, occ: string): number | null {
  if (year === null) {
    return null;
  }
  const n = parseDate(occ).y - year;
  return n > 0 ? n : null;
}

export function shortDate(s: string): string {
  const { m, d } = parseDate(s);
  return `${MON[m - 1]} ${d}`;
}

export function weekdayShort(s: string): string {
  return WD[weekday(s)] ?? "";
}
