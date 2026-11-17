import type { Birthday, CalendarZoom, ListView, Settings } from "./api";
import { CalendarView } from "./CalendarView";
import { MONTHS, parseDate, turning } from "./dates";
import { compareNames, noDestination, plural, sortUpcoming, whenText, withDates } from "./format";
import type { Dated } from "./format";
import { MSG_GENERIC, MSG_UNAVAILABLE } from "./messages";
import { Avatar, BirthdayRow, Chevron, DestinationNotice } from "./parts";
import type { OpenDetail } from "./parts";
import type { Calendar } from "./useCalendar";

const ZOOMS: { value: CalendarZoom; label: string }[] = [
  { value: "year", label: "Year" },
  { value: "month", label: "Month" },
  { value: "week", label: "Week" },
];

const VIEWS: { value: ListView; label: string }[] = [
  { value: "upcoming", label: "Upcoming" },
  { value: "month", label: "By month" },
  { value: "name", label: "A–Z" },
  { value: "calendar", label: "Calendar" },
];

// The A-Z bucket for a name: its first letter ignoring case and accents ("Elodie" and "Élodie" both file under E);
// digits, emoji and other non-letters go in "#".
export function letterOf(name: string): string {
  const first = Array.from(name.trim().normalize("NFD"))[0] ?? "";
  return /\p{L}/u.test(first) ? first.toLocaleUpperCase() : "#";
}

export function groupByLetter(list: Dated[]): { letter: string; items: Dated[] }[] {
  const sorted = list.slice().sort((a, b) => compareNames(a.b.name, b.b.name));
  const groups = new Map<string, Dated[]>();
  for (const d of sorted) {
    const letter = letterOf(d.b.name);
    groups.set(letter, [...(groups.get(letter) ?? []), d]);
  }
  return Array.from(groups, ([letter, items]) => ({ letter, items })).sort((a, b) =>
    a.letter === "#" ? 1 : b.letter === "#" ? -1 : compareNames(a.letter, b.letter),
  );
}

export function groupByMonth(list: Dated[]): { month: number; items: Dated[] }[] {
  const out: { month: number; items: Dated[] }[] = [];
  for (let m = 1; m <= 12; m++) {
    const items = list
      .filter((d) => d.b.month === m)
      .sort((a, b) => a.b.day - b.b.day || compareNames(a.b.name, b.b.name));
    if (items.length > 0) {
      out.push({ month: m, items });
    }
  }
  return out;
}

function Hero({ hero, week, open }: { hero: Dated; week: number; open: OpenDetail }) {
  const first = hero.b.name.trim().split(/\s+/)[0] ?? hero.b.name;
  const age = turning(hero.b.year, hero.occ);
  const line = age !== null ? `${first} turns ${age}` : `${hero.b.name}'s birthday`;
  return (
    <div className="hero">
      <Avatar name={hero.b.name} big />
      <div>
        <div className="eyebrow">{hero.days === 0 ? "Today" : `Next up · ${whenText(hero.days)}`}</div>
        <div className="big">
          <a className="link" href={`#/b/${hero.b.id}`} data-bid={hero.b.id} onClick={(e) => open(e, hero.b.id, "birthdays")}>
            {line}
          </a>
          {hero.days === 0 && <span aria-hidden="true"> {"\u{1F389}"}</span>}
        </div>
        {week > 0 && <div className="meta">{plural(week, "birthday")} in the next 7 days</div>}
      </div>
      <Chevron />
    </div>
  );
}

function Rows({ items, open }: { items: Dated[]; open: OpenDetail }) {
  return (
    <ul className="items">
      {items.map((d) => (
        <BirthdayRow key={d.b.id} d={d} origin="birthdays" open={open} />
      ))}
    </ul>
  );
}

function Skeleton() {
  return (
    <>
      <p className="loading">Loading birthdays&hellip;</p>
      <ul className="items skeletons" aria-hidden="true">
        {[1, 2, 3].map((n) => (
          <li key={n}>
            <div className={`skeleton w${n}`} />
          </li>
        ))}
      </ul>
    </>
  );
}

export function BirthdaysTab({
  list,
  loading,
  alert,
  retry,
  view,
  viewDisabled,
  onView,
  today,
  open,
  settings,
  saveStatus,
  goAdd,
  cal,
}: {
  list: Birthday[] | null;
  loading: boolean;
  alert: "unavailable" | "generic" | null;
  retry: () => void;
  view: ListView;
  viewDisabled: boolean;
  onView: (v: ListView) => void;
  today: string;
  open: OpenDetail;
  settings: Settings | null;
  saveStatus: string;
  goAdd: () => void;
  cal: Calendar;
}) {
  const dated = list === null ? [] : withDates(list, today);
  const dest = noDestination(settings);
  // The banner waits for the list and shows only when a loaded birthday actually has a reminder on.
  const showBanner = dest !== null && list !== null && list.some((b) => b.reminder_offsets.length > 0);
  const todayMonth = parseDate(today).m;

  function body() {
    if (list === null) {
      return alert === null ? <Skeleton /> : null;
    }
    if (list.length === 0) {
      return (
        <div className="emptystate">
          <p className="display">No birthdays yet.</p>
          <p className="empty">Add the people you want to remember.</p>
          <button className="primary" type="button" onClick={goAdd}>
            Add a birthday
          </button>
        </div>
      );
    }
    if (view === "upcoming") {
      const sorted = sortUpcoming(dated);
      const hero = sorted[0];
      const week = sorted.filter((d) => d.days <= 7).length;
      return (
        <>
          {hero !== undefined && <Hero hero={hero} week={week} open={open} />}
          <Rows items={sorted.slice(1)} open={open} />
        </>
      );
    }
    if (view === "month") {
      return (
        <>
          {groupByMonth(dated).map((g) => (
            <div key={g.month}>
              <h3 className="group">
                {MONTHS[g.month - 1]}
                {g.month === todayMonth && <span className="meta"> {"·"} this month</span>}
              </h3>
              <Rows items={g.items} open={open} />
            </div>
          ))}
        </>
      );
    }
    if (view === "name") {
      return (
        <>
          {groupByLetter(dated).map((g) => (
            <div key={g.letter}>
              <h3 className="group">{g.letter}</h3>
              <Rows items={g.items} open={open} />
            </div>
          ))}
        </>
      );
    }
    return <CalendarView list={list} today={today} open={open} cal={cal} disabled={viewDisabled} />;
  }

  return (
    <section aria-labelledby="bd-h">
      <div className="row heading">
        <h2 id="bd-h" data-screen-h tabIndex={-1}>
          Birthdays
        </h2>
        {list !== null && <span className="meta">{plural(list.length, "birthday")}</span>}
      </div>
      {showBanner && dest !== null && (
        <div className="banner">
          <DestinationNotice kind={dest} />
        </div>
      )}
      {list !== null && list.length > 0 && (
        <div className="toolbar">
          <fieldset className="seg">
            <legend className="sr-only">Show birthdays as</legend>
            {VIEWS.map((v) => (
              <label key={v.value} className={view === v.value ? "on" : undefined}>
                <input
                  type="radio"
                  name="view"
                  value={v.value}
                  checked={view === v.value}
                  disabled={viewDisabled}
                  onChange={() => onView(v.value)}
                />
                <span>{v.label}</span>
              </label>
            ))}
          </fieldset>
          {view === "calendar" && (
            <fieldset className="seg">
              <legend className="sr-only">Calendar zoom</legend>
              {ZOOMS.map((z) => (
                <label key={z.value} className={cal.zoom === z.value ? "on" : undefined}>
                  <input
                    type="radio"
                    name="zoom"
                    value={z.value}
                    checked={cal.zoom === z.value}
                    disabled={viewDisabled}
                    onChange={() => cal.setZoom(z.value)}
                  />
                  <span>{z.label}</span>
                </label>
              ))}
            </fieldset>
          )}
        </div>
      )}
      <p className="status" role="status" aria-live="polite" data-testid="view-status">
        {saveStatus}
      </p>
      {alert !== null && (
        <div className="alert" role="alert">
          <p>
            <strong>Couldn't load your birthdays.</strong> {alert === "unavailable" ? MSG_UNAVAILABLE : MSG_GENERIC}
          </p>
          <button className="secondary" type="button" aria-disabled={loading ? "true" : undefined} onClick={retry}>
            Try again
          </button>
        </div>
      )}
      <div className="viewout" aria-busy={loading ? "true" : undefined}>
        {body()}
      </div>
    </section>
  );
}
