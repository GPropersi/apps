import type { Birthday, Settings } from "./api";
import { daysUntil, observedDay, occurrence, parseDate, shortDate, turning, weekdayShort } from "./dates";

export type Dated = { b: Birthday; occ: string; days: number };

const collator = new Intl.Collator("en", { sensitivity: "base" });

export function compareNames(a: string, b: string): number {
  return collator.compare(a, b) || (a < b ? -1 : a > b ? 1 : 0);
}

export function withDates(list: Birthday[], today: string): Dated[] {
  return list.map((b) => {
    const occ = occurrence(b.month, b.day, today);
    return { b, occ, days: daysUntil(today, occ) };
  });
}

export function sortUpcoming(list: Dated[]): Dated[] {
  return list.slice().sort((a, b) => (a.occ < b.occ ? -1 : a.occ > b.occ ? 1 : compareNames(a.b.name, b.b.name)));
}

export function plural(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? "" : "s"}`;
}

// "Today", "Tomorrow", "in N days" under 7, "N days" under 60, else "N months".
export function whenText(days: number): string {
  if (days <= 0) {
    return "Today";
  }
  if (days === 1) {
    return "Tomorrow";
  }
  if (days < 7) {
    return `in ${days} days`;
  }
  if (days < 60) {
    return `${days} days`;
  }
  return `${Math.round(days / 30.44)} months`;
}

export function chipClass(days: number): string {
  return days <= 0 ? "chip today" : days <= 7 ? "chip soon" : "chip";
}

// The part of the owner's email before the "@".
export function ownerName(b: Birthday): string {
  return b.owner_email.split("@")[0] ?? b.owner_email;
}

// True for a Feb 29 birthday observed on another day (Feb 28) on `date`.
export function isObservedEarly(b: Birthday, date: string): boolean {
  return b.month === 2 && b.day === 29 && observedDay(b.month, b.day, parseDate(date).y) !== b.day;
}

// "Wkd, Mon D - turns N - born Feb 29 - from X" (joined with a middle dot).
export function metaText(d: Dated): string {
  const parts = [`${weekdayShort(d.occ)}, ${shortDate(d.occ)}`];
  const age = turning(d.b.year, d.occ);
  if (age !== null) {
    parts.push(`turns ${age}`);
  }
  if (isObservedEarly(d.b, d.occ)) {
    parts.push("born Feb 29");
  }
  if (!d.b.is_mine) {
    parts.push(`from ${ownerName(d.b)}`);
  }
  return parts.join(" · ");
}

// "Added Sam - Nov 14, in 5 days."
export function addedText(b: Birthday, today: string): string {
  const d = withDates([b], today)[0];
  if (d === undefined) {
    return `Added ${b.name}.`;
  }
  const when = d.days === 0 ? "today" : d.days === 1 ? "tomorrow" : `in ${d.days} days`;
  return `Added ${b.name} - ${shortDate(d.occ)}, ${when}.`;
}

// No usable place to send a reminder: no ntfy and no non-stale destination. "stale" when destinations exist but all
// are stale, "none" when there are none.
export function noDestination(s: Settings | null): "none" | "stale" | null {
  if (s === null || s.ntfy || s.destinations - s.stale_destinations > 0) {
    return null;
  }
  return s.destinations > 0 ? "stale" : "none";
}
