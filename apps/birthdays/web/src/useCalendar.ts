import { useRef, useState } from "react";
import type { CalendarZoom } from "./api";
import { anchorOf, inPeriod, shiftPeriod, startOfPeriod } from "./calendar";
import type { CalendarState } from "./calendar";

export type Calendar = {
  state: CalendarState;
  zoom: CalendarZoom;
  // True once after a zoom change or the Year -> Month drill-down (and clears): the calendar should focus its period
  // heading now.
  takeFocus: () => boolean;
  prev: () => void;
  next: () => void;
  goToday: () => void;
  select: (date: string) => void;
  setZoom: (z: CalendarZoom) => void;
  drillToMonth: (monthStart: string) => void;
};

// The calendar's period and selected day are app-level state: they survive a detail round trip and a tab change,
// open on today's period, are cleared by a reload and never saved to the server (only the zoom is).
export function useCalendar(today: string, zoom: CalendarZoom, saveZoom: (z: CalendarZoom) => void): Calendar {
  const [state, setState] = useState<CalendarState>(() => ({ shown: today, selected: null }));
  const focusPending = useRef(false);

  const move = (dir: 1 | -1) => setState((s) => ({ shown: shiftPeriod(zoom, s.shown, dir), selected: null }));

  return {
    state,
    zoom,
    takeFocus: () => {
      const pending = focusPending.current;
      focusPending.current = false;
      return pending;
    },
    prev: () => move(-1),
    next: () => move(1),
    goToday: () => setState({ shown: today, selected: null }),
    select: (date) => setState({ shown: date, selected: date }),
    setZoom: (z) => {
      if (z === zoom) {
        return;
      }
      focusPending.current = true;
      setState((s) => ({ shown: anchorOf(zoom, s.shown, s.selected, today), selected: s.selected }));
      saveZoom(z);
    },
    drillToMonth: (monthStart) => {
      focusPending.current = true;
      setState({
        shown: inPeriod("month", monthStart, today) ? today : startOfPeriod("month", monthStart),
        selected: null,
      });
      saveZoom("month");
    },
  };
}
