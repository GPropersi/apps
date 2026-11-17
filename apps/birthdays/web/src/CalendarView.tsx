import { useEffect, useMemo, useRef, useState } from "react";
import type { RefObject } from "react";
import type { Birthday } from "./api";
import { effectiveSelection, indexBirthdays, monthDays, monthWeeks, periodLabel, startOfPeriod, yearsOf } from "./calendar";
import type { DayIndex } from "./calendar";
import { tintIndex } from "./colors";
import { MONTHS, WD, WDL, addDays, daysUntil, formatDate, parseDate, turning, weekday } from "./dates";
import { isObservedEarly, ownerName, plural } from "./format";
import type { Dated } from "./format";
import { Avatar, BirthdayRow, Chevron } from "./parts";
import type { OpenDetail } from "./parts";
import type { Calendar } from "./useCalendar";
import { announce } from "./util";

const NONE: Birthday[] = [];

function longDay(date: string): string {
  const { m, d } = parseDate(date);
  return `${MONTHS[m - 1]} ${d}`;
}

function PeriodNav({ cal, label, headingRef }: { cal: Calendar; label: string; headingRef: RefObject<HTMLHeadingElement | null> }) {
  return (
    <div className="periodnav">
      <button className="secondary" type="button" onClick={cal.prev}>
        <span aria-hidden="true">&lsaquo;</span>
        <span className="sr-only">Previous {cal.zoom}</span>
      </button>
      <h3 ref={headingRef} tabIndex={-1} aria-live="polite">
        {label}
      </h3>
      <button className="secondary" type="button" onClick={cal.goToday}>
        Today
      </button>
      <button className="secondary" type="button" onClick={cal.next}>
        <span aria-hidden="true">&rsaquo;</span>
        <span className="sr-only">Next {cal.zoom}</span>
      </button>
    </div>
  );
}

function dayLabel(date: string, today: string, count: number): string {
  return [longDay(date), date === today ? "today" : null, count > 0 ? plural(count, "birthday") : null]
    .filter((p): p is string => p !== null)
    .join(", ");
}

function MonthGrid({
  cal,
  index,
  today,
  open,
  announceDay,
}: {
  cal: Calendar;
  index: DayIndex;
  today: string;
  open: OpenDetail;
  announceDay: (text: string) => void;
}) {
  const { shown, selected } = cal.state;
  const rows = monthWeeks(shown);
  const chosen = effectiveSelection(shown, selected, today);
  const chosenPeople = chosen === null ? NONE : (index.get(chosen) ?? NONE);
  const caption = periodLabel("month", shown);

  return (
    <>
      <table className="cal">
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr>
            {WD.map((w, i) => (
              <th key={w} scope="col">
                <abbr title={WDL[i]}>{w}</abbr>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, r) => (
            <tr key={r}>
              {row.map((date, c) => {
                if (date === null) {
                  return <td key={c} className="blank" />;
                }
                const people = index.get(date) ?? NONE;
                return (
                  <td key={c} className={date === today ? "today" : undefined}>
                    <button
                      className="day"
                      type="button"
                      data-date={date}
                      aria-pressed={date === chosen}
                      aria-label={dayLabel(date, today, people.length)}
                      onClick={() => {
                        cal.select(date);
                        announceDay(`${longDay(date)} - ${plural(people.length, "birthday")}`);
                      }}
                    >
                      <span className="num" aria-hidden="true">
                        {parseDate(date).d}
                      </span>
                      {people.length > 0 && <span className="dot" aria-hidden="true" />}
                    </button>
                    {people.length > 0 && (
                      <ul className="names">
                        {people.map((b) => (
                          <li key={b.id}>
                            <a
                              className={`link tint${tintIndex(b.name)}`}
                              href={`#/b/${b.id}`}
                              data-bid={b.id}
                              onClick={(e) => open(e, b.id, "birthdays")}
                            >
                              {b.name}
                            </a>
                          </li>
                        ))}
                      </ul>
                    )}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
      {chosen === null ? (
        <p className="empty dayline">Tap a day to see its birthdays.</p>
      ) : (
        <div className="dayline">
          <h3>
            {WDL[weekday(chosen)]}, {longDay(chosen)}
          </h3>
          {chosenPeople.length === 0 ? (
            <p className="empty">No birthdays on this day.</p>
          ) : (
            <ul className="items">
              {chosenPeople.map((b) => {
                const d: Dated = { b, occ: chosen, days: daysUntil(today, chosen) };
                return <BirthdayRow key={b.id} d={d} origin="birthdays" open={open} showChip={d.days >= 0} />;
              })}
            </ul>
          )}
        </div>
      )}
    </>
  );
}

function YearGrid({ cal, index, today, disabled }: { cal: Calendar; index: DayIndex; today: string; disabled: boolean }) {
  const year = parseDate(startOfPeriod("year", cal.state.shown)).y;
  return (
    <div className="yeargrid">
      {MONTHS.map((name, i) => {
        const m = i + 1;
        const monthStart = formatDate(year, m, 1);
        const rows = monthWeeks(monthStart);
        const count = monthDays(monthStart).reduce((n, d) => n + (index.get(d)?.length ?? 0), 0);
        return (
          <div className="mini" key={name}>
            <h3>
              <button
                className="link"
                type="button"
                disabled={disabled}
                aria-label={`${name}, ${plural(count, "birthday")}. Open month`}
                onClick={() => cal.drillToMonth(monthStart)}
              >
                {name}
              </button>
              {count > 0 && (
                <span className="chip" aria-hidden="true">
                  {count}
                </span>
              )}
            </h3>
            <table className="minical" aria-hidden="true">
              <thead>
                <tr>
                  {WD.map((w) => (
                    <th key={w}>{w.slice(0, 1)}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((row, r) => (
                  <tr key={r}>
                    {row.map((date, c) => (
                      <td
                        key={c}
                        data-date={date ?? undefined}
                        className={date === null ? undefined : [date === today ? "today" : null, index.has(date) ? "has" : null].filter((c) => c !== null).join(" ") || undefined}
                      >
                        {date !== null && <span>{parseDate(date).d}</span>}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })}
    </div>
  );
}

function WeekList({ cal, index, today, open }: { cal: Calendar; index: DayIndex; today: string; open: OpenDetail }) {
  const start = startOfPeriod("week", cal.state.shown);
  return (
    <ul className="items week">
      {Array.from({ length: 7 }, (_, i) => addDays(start, i)).map((date) => {
        const people = index.get(date) ?? NONE;
        const { d } = parseDate(date);
        return (
          <li key={date} data-date={date}>
            <div className={date === today ? "wd today" : "wd"}>
              <strong>
                {WD[weekday(date)]} {d}
              </strong>
              {date === today && <div className="chip today">Today</div>}
            </div>
            {people.length === 0 ? (
              <span className="meta">No birthdays</span>
            ) : (
              <ul className="wlist">
                {people.map((b) => {
                  const bits: string[] = [];
                  const age = turning(b.year, date);
                  if (age !== null) {
                    bits.push(`turns ${age}`);
                  }
                  if (isObservedEarly(b, date)) {
                    bits.push("born Feb 29");
                  }
                  if (!b.is_mine) {
                    bits.push(`shared by ${ownerName(b)}`);
                  }
                  return (
                    <li key={b.id} className="wperson">
                      <Avatar name={b.name} />
                      <div className="pinfo">
                        <a className="link" href={`#/b/${b.id}`} data-bid={b.id} onClick={(e) => open(e, b.id, "birthdays")}>
                          {b.name}
                        </a>
                        {bits.length > 0 && <div className="meta">{bits.join(" · ")}</div>}
                      </div>
                      <Chevron />
                    </li>
                  );
                })}
              </ul>
            )}
          </li>
        );
      })}
    </ul>
  );
}

export function CalendarView({
  list,
  today,
  open,
  cal,
  disabled,
}: {
  list: Birthday[];
  today: string;
  open: OpenDetail;
  cal: Calendar;
  disabled: boolean;
}) {
  const headingRef = useRef<HTMLHeadingElement>(null);
  const [dayNotice, setDayNotice] = useState("");
  const { shown } = cal.state;
  const index = useMemo(() => indexBirthdays(list, yearsOf(cal.zoom, shown)), [list, cal.zoom, shown]);

  // A zoom change or the Year -> Month drill-down moves focus to the new period heading; Previous / Next / Today leave it
  // on the button that was pressed. No dependency list on purpose: the flag is set in an event handler (not state), so
  // the effect must look at it after every render, and takeFocus clears it so it fires once.
  useEffect(() => {
    if (cal.takeFocus()) {
      headingRef.current?.focus();
    }
  });

  return (
    <div className="calendar">
      <PeriodNav cal={cal} label={periodLabel(cal.zoom, shown)} headingRef={headingRef} />
      <p className="sr-only" role="status" aria-live="polite" data-testid="day-status">
        {dayNotice}
      </p>
      {cal.zoom === "month" && (
        <MonthGrid cal={cal} index={index} today={today} open={open} announceDay={(t) => announce(setDayNotice, t)} />
      )}
      {cal.zoom === "year" && <YearGrid cal={cal} index={index} today={today} disabled={disabled} />}
      {cal.zoom === "week" && <WeekList cal={cal} index={index} today={today} open={open} />}
    </div>
  );
}
