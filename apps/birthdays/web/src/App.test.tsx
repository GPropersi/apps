import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { Birthday, Settings } from "./api";
import { groupByLetter, groupByMonth, letterOf } from "./BirthdaysTab";
import { draftTag } from "./draft";
import { withDates } from "./format";

type Handler = (init?: RequestInit) => Response | Promise<Response>;
type Routes = Record<string, Handler>;

const JSON_CT = { "Content-Type": "application/json" };
const HTML_CT = { "Content-Type": "text/html" };
const EMAIL = "alex@example.com";
const TODAY = "2026-11-16";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_CT });
}
function html(status: number): Response {
  return new Response("<html>edge</html>", { status, headers: HTML_CT });
}
function deferred() {
  let resolve!: (r: Response) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const SETTINGS: Settings = {
  auto_remind: false,
  default_offsets: [7, 1],
  start_tab: "auto",
  list_view: "upcoming",
  calendar_zoom: "month",
  color_scheme: "confetti",
  ntfy: true,
  destinations: 0,
  stale_destinations: 0,
};
function settings(over: Partial<Settings> = {}): Settings {
  return { ...SETTINGS, ...over };
}
function bd(id: number, name: string, month: number, day: number, over: Partial<Birthday> = {}): Birthday {
  return {
    id,
    name,
    month,
    day,
    year: null,
    is_mine: true,
    owner_email: EMAIL,
    reminder_offsets: [],
    ...over,
  };
}

// Pinned "today" is Monday 2026-11-16.
const SAM = bd(1, "Sam Rivera", 11, 16, { year: 1990, reminder_offsets: [7, 1] });
const ADA = bd(2, "Ada Lovelace", 11, 17);
const ZED = bd(3, "Zed Young", 11, 20, { is_mine: false, owner_email: "pat@example.com" });
const ELO = bd(4, "Élodie Martin", 12, 25);
const BOB = bd(5, "Bob Stone", 3, 1);
const NUM = bd(6, "1st Boy", 5, 5);
const LIST = [BOB, ELO, ZED, SAM, NUM, ADA];

const ME = (s: Settings = SETTINGS): Handler => () => json({ email: EMAIL, settings: s });
const BIRTHDAYS = (list: Birthday[]): Handler => () => json({ birthdays: list });

let calls: { key: string; body: unknown }[] = [];

function mount(routes: Routes = {}) {
  calls = [];
  const table: Routes = { "GET /api/me": ME(), "GET /api/birthdays": BIRTHDAYS(LIST), ...routes };
  vi.stubGlobal(
    "fetch",
    vi.fn((path: string, init?: RequestInit) => {
      const key = `${init?.method ?? "GET"} ${path}`;
      calls.push({ key, body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined });
      const h = table[key];
      return Promise.resolve(h ? h(init) : html(404));
    }),
  );
  return { user: userEvent.setup(), ...render(<App />) };
}

function count(key: string): number {
  return calls.filter((c) => c.key === key).length;
}
function bodyOf(key: string, n = 0): unknown {
  return calls.filter((c) => c.key === key)[n]?.body;
}

function setMedia(opts: { narrow: boolean; fine: boolean }) {
  vi.stubGlobal(
    "matchMedia",
    (q: string) =>
      ({
        matches: q.includes("max-width") ? opts.narrow : q.includes("pointer: fine") ? opts.fine : false,
        media: q,
        addEventListener: () => undefined,
        removeEventListener: () => undefined,
      }) as unknown as MediaQueryList,
  );
}

function go(hash: string, state: unknown = null) {
  window.history.replaceState(state, "", hash === "" ? "/" : hash);
}

const nameInput = () => screen.getByLabelText("Name");
const dayInput = () => screen.getByLabelText("Day");
const yearInput = () => screen.getByLabelText(/^Year/);
const addButton = () => screen.getByRole("button", { name: "Add birthday" });
const month = (full: string) => screen.getByRole("radio", { name: full });
const remindBox = () => screen.getByRole("checkbox", { name: /^Remind me/ });
const nav = () => screen.getByRole("navigation", { name: "Main" });
const backLink = () => within(screen.getByRole("navigation", { name: "Back" })).getByRole("link");

async function loaded() {
  await waitFor(() => expect(screen.getByRole("heading", { level: 2 })).toBeInTheDocument());
}

// The Add form is disabled until GET /api/me has answered; typing into it earlier is silently dropped.
async function nameField() {
  const input = await screen.findByLabelText("Name");
  await waitFor(() => expect(input).toBeEnabled());
  return input;
}

// The view radios stay disabled until GET /api/me has answered; wait for that before using one.
async function viewRadio(name: string) {
  const radio = await screen.findByRole("radio", { name });
  await waitFor(() => expect(radio).toBeEnabled());
  return radio;
}

function setScrollY(y: number) {
  Object.defineProperty(window, "scrollY", { value: y, configurable: true });
}

// The arguments of every focus() call made on `el`.
function focusArgs(spy: { mock: { calls: unknown[][]; contexts: unknown[] } }, el: Element): unknown[] {
  return spy.mock.calls.filter((_, i) => spy.mock.contexts[i] === el).map((c) => c[0]);
}

// What a browser does for Back/Forward: the location changes, then popstate and hashchange both fire.
async function browserNavigate(hash: string, state: unknown = null) {
  window.history.replaceState(state, "", hash);
  await act(async () => {
    window.dispatchEvent(new PopStateEvent("popstate"));
  });
  await act(async () => {
    window.dispatchEvent(new HashChangeEvent("hashchange"));
  });
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2026, 10, 16, 12, 0, 0));
  setMedia({ narrow: false, fine: true });
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  setScrollY(0);
  Object.defineProperty(window, "visualViewport", { value: undefined, configurable: true });
});

describe("start tab and routes", () => {
  it.each([
    ["auto", true, "#/add"],
    ["auto", false, "#/birthdays"],
    ["add", false, "#/add"],
    ["add", true, "#/add"],
    ["view", true, "#/birthdays"],
    ["view", false, "#/birthdays"],
  ])("start_tab %s at narrow=%s resolves to %s", async (start, narrow, want) => {
    setMedia({ narrow, fine: true });
    mount({ "GET /api/me": ME(settings({ start_tab: start as Settings["start_tab"] })) });
    await waitFor(() => expect(window.location.hash).toBe(want));
  });

  it("does not push a history entry when resolving the start tab", async () => {
    const before = window.history.length;
    mount();
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
    expect(window.history.length).toBe(before);
  });

  it("an explicit hash overrides the start tab setting", async () => {
    go("#/add");
    mount({ "GET /api/me": ME(settings({ start_tab: "view" })) });
    expect(await screen.findByRole("heading", { name: "Add a birthday" })).toBeInTheDocument();
    expect(window.location.hash).toBe("#/add");
  });

  it("marks the current tab with aria-current and follows the tab links", async () => {
    const { user } = mount();
    await screen.findByRole("heading", { name: "Birthdays" });
    expect(within(nav()).getByRole("link", { name: /Birthdays/ })).toHaveAttribute("aria-current", "page");
    expect(within(nav()).getByRole("link", { name: /Add/ })).not.toHaveAttribute("aria-current");
    await user.click(within(nav()).getByRole("link", { name: /Settings/ }));
    expect(await screen.findByRole("heading", { name: "Settings" })).toBeInTheDocument();
    expect(within(nav()).getByRole("link", { name: /Settings/ })).toHaveAttribute("aria-current", "page");
  });

  it("the tab links are real anchors", async () => {
    mount();
    await loaded();
    expect(within(nav()).getByRole("link", { name: /Add/ })).toHaveAttribute("href", "#/add");
    expect(within(nav()).getByRole("link", { name: /Birthdays/ })).toHaveAttribute("href", "#/birthdays");
    expect(within(nav()).getByRole("link", { name: /Settings/ })).toHaveAttribute("href", "#/settings");
  });

  it("an unknown hash resolves like the start tab", async () => {
    go("#/nonsense");
    mount();
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
  });

  it("autofocuses the name field only on a fine pointer, and only on first load", async () => {
    go("#/add");
    mount();
    await waitFor(() => expect(nameInput()).toHaveFocus());
  });

  it("does not autofocus the name field on a touch device", async () => {
    setMedia({ narrow: true, fine: false });
    go("#/add");
    mount();
    await loaded();
    expect(nameInput()).not.toHaveFocus();
  });

  it("hides the tab bar only while the keyboard is open (visualViewport)", async () => {
    const listeners: (() => void)[] = [];
    const vv = {
      height: window.innerHeight,
      addEventListener: (_: string, fn: () => void) => listeners.push(fn),
      removeEventListener: () => undefined,
    };
    Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
    mount();
    await loaded();
    expect(nav()).not.toHaveAttribute("data-kbd");
    vv.height = window.innerHeight - 300;
    act(() => listeners.forEach((fn) => fn()));
    expect(nav()).toHaveAttribute("data-kbd", "open");
    vv.height = window.innerHeight - 40;
    act(() => listeners.forEach((fn) => fn()));
    expect(nav()).not.toHaveAttribute("data-kbd");
  });
});

describe("Add tab", () => {
  it("adds a birthday, sends empty offsets when unticked, clears the form and lists it under Added just now", async () => {
    go("#/add");
    const created = bd(9, "Mia Chen", 11, 21, { reminder_offsets: [7, 1] });
    const { user } = mount({ "POST /api/birthdays": () => json(created, 201) });
    await user.type(await nameField(), "Mia Chen");
    await user.click(month("November"));
    await user.type(dayInput(), "21");
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia Chen", month: 11, day: 21, offsets: [] });
    expect(await screen.findByRole("heading", { name: "Added just now" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Mia Chen" })).toHaveAttribute("href", "#/b/9");
    expect(nameInput()).toHaveValue("");
    expect(nameInput()).toHaveFocus();
    expect(screen.getByTestId("add-status")).toHaveTextContent("Added Mia Chen - Nov 21, in 5 days.");
  });

  it("sends the year and the default offsets when remind is ticked", async () => {
    go("#/add");
    const { user } = mount({ "POST /api/birthdays": () => json(bd(9, "Mia", 2, 29, { year: 2000 }), 201) });
    await user.type(await nameField(), "  Mia  ");
    await user.click(month("February"));
    await user.type(dayInput(), "29");
    await user.type(yearInput(), "2000");
    await user.click(remindBox());
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 2, day: 29, year: 2000, offsets: [7, 1] });
  });

  it("shows a field error and focuses the first invalid field, without calling the API", async () => {
    go("#/add");
    const { user } = mount();
    await nameField();
    await user.click(addButton());
    expect(screen.getByText("Enter a name.")).toBeInTheDocument();
    expect(nameInput()).toHaveFocus();
    expect(nameInput()).toHaveAttribute("aria-invalid", "true");
    await user.type(nameInput(), "Mia");
    expect(nameInput()).not.toHaveAttribute("aria-invalid");
    await user.click(addButton());
    expect(screen.getByText("Pick a month.")).toBeInTheDocument();
    expect(month("January")).toHaveFocus();
    await user.click(month("February"));
    await user.click(addButton());
    expect(screen.getByText("Enter a day.")).toBeInTheDocument();
    expect(dayInput()).toHaveFocus();
    await user.type(dayInput(), "30");
    await user.click(addButton());
    expect(screen.getByText("February has 29 days.")).toBeInTheDocument();
    await user.clear(dayInput());
    await user.type(dayInput(), "29");
    await user.type(yearInput(), "2001");
    await user.click(addButton());
    expect(screen.getByText("2001 had no February 29.")).toBeInTheDocument();
    await user.clear(yearInput());
    await user.type(yearInput(), "1800");
    await user.click(addButton());
    expect(screen.getByText("Enter a year from 1900 to 2200.")).toBeInTheDocument();
    expect(yearInput()).toHaveFocus();
    expect(count("POST /api/birthdays")).toBe(0);
  });

  it("maps server field errors back to their fields and keeps the typed values", async () => {
    go("#/add");
    const { user } = mount({ "POST /api/birthdays": () => json({ error: "invalid_date" }, 400) });
    await user.type(await nameField(), "Mia");
    await user.click(month("March"));
    await user.type(dayInput(), "5");
    await user.click(addButton());
    expect(await screen.findByText("That date doesn't exist. Check the month and day.")).toBeInTheDocument();
    expect(dayInput()).toHaveFocus();
    expect(nameInput()).toHaveValue("Mia");
  });

  it("shows other server failures as a general alert", async () => {
    go("#/add");
    const { user } = mount({ "POST /api/birthdays": () => json({ error: "too_many_birthdays" }, 409) });
    await user.type(await nameField(), "Mia");
    await user.click(month("March"));
    await user.type(dayInput(), "5");
    await user.click(addButton());
    expect(await within(screen.getByTestId("add-alert")).findByText(/limit of 500 birthdays/)).toBeInTheDocument();
  });

  it("ignores a second submit while one is in flight", async () => {
    go("#/add");
    const d = deferred();
    const { user } = mount({ "POST /api/birthdays": () => d.promise });
    await user.type(await nameField(), "Mia");
    await user.click(month("March"));
    await user.type(dayInput(), "5");
    await user.click(addButton());
    await user.click(addButton());
    expect(count("POST /api/birthdays")).toBe(1);
    await act(async () => {
      d.resolve(json(bd(9, "Mia", 3, 5), 201));
    });
  });

  it("Enter in the name field moves focus to the month group instead of submitting", async () => {
    go("#/add");
    const { user } = mount();
    await user.type(await nameField(), "Mia{Enter}");
    expect(month("January")).toHaveFocus();
    expect(screen.queryByText("Pick a month.")).not.toBeInTheDocument();
    expect(count("POST /api/birthdays")).toBe(0);
  });

  it("Enter focuses the chosen month when there is one", async () => {
    go("#/add");
    const { user } = mount();
    await user.type(await nameField(), "Mia");
    await user.click(month("June"));
    await user.click(nameInput());
    await user.keyboard("{Enter}");
    expect(month("June")).toHaveFocus();
  });

  it("Enter that confirms an IME composition does not move focus", async () => {
    go("#/add");
    mount();
    const input = await nameField();
    input.focus();
    fireEvent.keyDown(input, { key: "Enter", isComposing: true, keyCode: 229 });
    expect(input).toHaveFocus();
    fireEvent.keyDown(input, { key: "Enter", keyCode: 229 });
    expect(input).toHaveFocus();
  });


  it("defaults the checkbox from auto_remind until the person touches it", async () => {
    go("#/add");
    const { user } = mount({ "GET /api/me": ME(settings({ auto_remind: true })) });
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.click(remindBox());
    expect(remindBox()).not.toBeChecked();
  });

  it("restores a draft from sessionStorage as touched, and mirrors edits to it", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: null }),
    );
    go("#/add");
    const { user } = mount({ "GET /api/me": ME(settings({ auto_remind: true })) });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(month("April")).toBeChecked();
    expect(dayInput()).toHaveValue("9");
    await user.type(nameInput(), "er");
    await waitFor(() => expect(window.sessionStorage.getItem("birthdays:add-draft") ?? "").toContain("Kepter"));
  });

  it("a restored draft's remind counts as touched: auto_remind never overwrites an explicit false", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: false }),
    );
    go("#/add");
    mount({ "GET /api/me": ME(settings({ auto_remind: true })) });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(remindBox()).not.toBeChecked();
  });

  it("does not restore a draft saved for a different email", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag("other@example.com"), name: "Nope", month: 4, day: "9", year: "", remind: null }),
    );
    go("#/add");
    mount();
    await nameField();
    await waitFor(() => expect(count("GET /api/me")).toBe(1));
    expect(nameInput()).toHaveValue("");
  });
});

describe("session handling", () => {
  it("an expired session shows the reload banner with the draft copy on Add and disables the form", async () => {
    go("#/add");
    mount({ "GET /api/me": () => html(200), "GET /api/birthdays": () => html(200) });
    const alert = (await screen.findByText("Your sign-in has expired.")).closest(".alert") as HTMLElement;
    expect(alert).toHaveTextContent("Your birthday details are still here.");
    expect(screen.getByRole("button", { name: "Reload" })).toHaveFocus();
    expect(nameInput()).toBeDisabled();
    expect(addButton()).toBeDisabled();
  });

  it("uses the plain reload copy on other screens", async () => {
    go("#/birthdays");
    mount({ "GET /api/me": () => html(200), "GET /api/birthdays": () => html(200) });
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("Reload to sign in again.");
    expect(alert).not.toHaveTextContent("still here");
  });

  it("an unauthenticated response shows the confirm-sign-in banner", async () => {
    go("#/birthdays");
    mount({
      "GET /api/me": () => json({ error: "unauthenticated" }, 401),
      "GET /api/birthdays": () => json({ error: "unauthenticated" }, 401),
    });
    expect(await screen.findByText("We couldn't confirm your sign-in.")).toBeInTheDocument();
  });

  it("a session loss while adding keeps the typed values", async () => {
    go("#/add");
    const { user } = mount({ "POST /api/birthdays": () => html(200) });
    await user.type(await nameField(), "Mia");
    await user.click(month("March"));
    await user.type(dayInput(), "5");
    await user.click(addButton());
    expect(await screen.findByText("Your sign-in has expired.")).toBeInTheDocument();
    expect(nameInput()).toHaveValue("Mia");
  });
});

describe("Birthdays tab", () => {
  it("Upcoming view: hero is the next birthday, then the rest in date order with chips", async () => {
    go("#/birthdays");
    mount();
    expect(await screen.findByText("Sam turns 36")).toBeInTheDocument();
    expect(screen.getByText("Today")).toHaveClass("eyebrow");
    const rows = screen.getAllByRole("listitem").filter((li) => li.querySelector("a.link"));
    expect(rows.map((li) => li.querySelector("a.link")?.textContent)).toEqual([
      "Ada Lovelace",
      "Zed Young",
      "Élodie Martin",
      "Bob Stone",
      "1st Boy",
    ]);
    expect(within(rows[0] as HTMLElement).getByText("Tomorrow")).toHaveClass("chip", "soon");
    expect(within(rows[1] as HTMLElement).getByText("in 4 days")).toHaveClass("chip", "soon");
    expect(within(rows[2] as HTMLElement).getByText("39 days")).toHaveClass("chip");
    expect(within(rows[2] as HTMLElement).getByText("39 days")).not.toHaveClass("soon");
    expect(screen.getByText("3 birthdays in the next 7 days")).toBeInTheDocument();
    expect(screen.getByText("6 birthdays")).toBeInTheDocument();
  });

  it("shows the meta line with the owner for shared birthdays, and a bell only with reminders on", async () => {
    go("#/birthdays");
    mount();
    const zed = (await screen.findByRole("link", { name: "Zed Young" })).closest("li") as HTMLElement;
    expect(zed).toHaveTextContent("Fri, Nov 20 · from pat");
    expect(within(zed).queryByText("Reminders on")).not.toBeInTheDocument();
    const ada = screen.getByRole("link", { name: "Ada Lovelace" }).closest("li") as HTMLElement;
    expect(ada).toHaveTextContent("Tue, Nov 17");
  });

  it("every row name is a real anchor to #/b/<id>", async () => {
    go("#/birthdays");
    mount();
    expect(await screen.findByRole("link", { name: "Ada Lovelace" })).toHaveAttribute("href", "#/b/2");
    expect(screen.getByRole("link", { name: "Sam turns 36" })).toHaveAttribute("href", "#/b/1");
  });

  it("By month view groups in month order, days ascending, and marks this month", async () => {
    go("#/birthdays");
    mount({ "GET /api/me": ME(settings({ list_view: "month" })) });
    await screen.findByRole("heading", { level: 3, name: /^November/ });
    const heads = screen.getAllByRole("heading", { level: 3 }).map((h) => h.textContent);
    expect(heads).toEqual(["March", "May", "November · this month", "December"]);
    const nov = screen.getByRole("heading", { level: 3, name: /^November/ }).parentElement as HTMLElement;
    expect(within(nov).getAllByRole("link").map((a) => a.textContent)).toEqual([
      "Sam Rivera",
      "Ada Lovelace",
      "Zed Young",
    ]);
  });

  it("A-Z view groups by first letter ignoring accents, with # last", async () => {
    go("#/birthdays");
    mount({ "GET /api/me": ME(settings({ list_view: "name" })) });
    await screen.findByRole("heading", { level: 3, name: "A" });
    expect(screen.getAllByRole("heading", { level: 3 }).map((h) => h.textContent)).toEqual([
      "A",
      "B",
      "E",
      "S",
      "Z",
      "#",
    ]);
  });

  it("changing the view applies at once and saves one PATCH", async () => {
    go("#/birthdays");
    const { user } = mount({ "PATCH /api/settings": () => json(settings({ list_view: "name" })) });
    await user.click(await viewRadio("A–Z"));
    expect(screen.getByRole("heading", { level: 3, name: "A" })).toBeInTheDocument();
    await waitFor(() => expect(screen.getByTestId("view-status")).toHaveTextContent("Saved."));
    expect(bodyOf("PATCH /api/settings")).toEqual({ list_view: "name" });
    expect(count("PATCH /api/settings")).toBe(1);
  });

  it("coalesces rapid view changes: one in flight, the last wins, Saved. only at the end", async () => {
    go("#/birthdays");
    const first = deferred();
    let n = 0;
    const { user } = mount({
      "PATCH /api/settings": () => {
        n += 1;
        return n === 1 ? first.promise : json(settings({ list_view: "month" }));
      },
    });
    await user.click(await viewRadio("A–Z"));
    await user.click(screen.getByRole("radio", { name: "By month" }));
    expect(count("PATCH /api/settings")).toBe(1);
    expect(screen.getByTestId("view-status")).toHaveTextContent("Saving…");
    await act(async () => {
      first.resolve(json(settings({ list_view: "name" })));
    });
    await waitFor(() => expect(screen.getByTestId("view-status")).toHaveTextContent("Saved."));
    expect(count("PATCH /api/settings")).toBe(2);
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ list_view: "month" });
    expect(screen.getByRole("radio", { name: "By month" })).toBeChecked();
  });

  it("a failed save keeps the local change and says so quietly", async () => {
    go("#/birthdays");
    const { user } = mount({ "PATCH /api/settings": () => json({ error: "internal" }, 500) });
    await user.click(await viewRadio("A–Z"));
    await waitFor(() =>
      expect(screen.getByTestId("view-status")).toHaveTextContent("Couldn't save that. It is changed on this screen only."),
    );
    expect(screen.getByRole("radio", { name: "A–Z" })).toBeChecked();
  });

  it("shows the empty state with a button to the Add tab", async () => {
    go("#/birthdays");
    const { user } = mount({ "GET /api/birthdays": BIRTHDAYS([]) });
    await screen.findByText("No birthdays yet.");
    await user.click(screen.getByRole("button", { name: "Add a birthday" }));
    expect(await screen.findByRole("heading", { name: "Add a birthday" })).toBeInTheDocument();
    expect(window.location.hash).toBe("#/add");
  });

  it("shows a load error with Try again", async () => {
    go("#/birthdays");
    let ok = false;
    const { user } = mount({ "GET /api/birthdays": () => (ok ? json({ birthdays: LIST }) : html(503)) });
    expect(await screen.findByText("Couldn't load your birthdays.")).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("Can't reach the app right now.");
    ok = true;
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("Sam turns 36")).toBeInTheDocument();
    expect(screen.queryByText("Couldn't load your birthdays.")).not.toBeInTheDocument();
  });

  it("ignores a stale list response that a newer request overtook", async () => {
    go("#/add");
    const slow = deferred();
    let n = 0;
    const created = bd(9, "Mia Chen", 11, 21);
    const { user } = mount({
      "GET /api/birthdays": () => {
        n += 1;
        if (n === 1) {
          return slow.promise;
        }
        return json({ birthdays: [created] });
      },
      "POST /api/birthdays": () => json(created, 201),
    });
    await user.type(await nameField(), "Mia Chen");
    await user.click(month("November"));
    await user.type(dayInput(), "21");
    await user.click(addButton());
    await waitFor(() => expect(count("GET /api/birthdays")).toBe(2));
    await act(async () => {
      slow.resolve(json({ birthdays: LIST }));
    });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    expect(await screen.findByText("1 birthday")).toBeInTheDocument();
    expect(screen.queryByText("Bob Stone")).not.toBeInTheDocument();
  });
});

describe("no-destination notice", () => {
  const NONE = settings({ ntfy: false, destinations: 0, stale_destinations: 0 });

  it("shows on Add when there is nowhere to send reminders, linking to Settings", async () => {
    go("#/add");
    mount({ "GET /api/me": ME(NONE) });
    expect(await screen.findByText(/Reminders have nowhere to go yet\./)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Set up a place to send them in Settings" })).toHaveAttribute(
      "href",
      "#/settings",
    );
  });

  it("uses the stale wording when every destination is stale", async () => {
    go("#/add");
    mount({ "GET /api/me": ME(settings({ ntfy: false, destinations: 2, stale_destinations: 2 })) });
    expect(await screen.findByText(/destinations stopped working/)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Check Settings" })).toBeInTheDocument();
  });

  it.each([
    ["ntfy on", settings({ ntfy: true })],
    ["a working destination", settings({ ntfy: false, destinations: 2, stale_destinations: 1 })],
  ])("is hidden with %s", async (_, s) => {
    go("#/add");
    mount({ "GET /api/me": ME(s) });
    await nameField();
    await waitFor(() => expect(count("GET /api/me")).toBe(1));
    expect(screen.queryByText(/nowhere to go|stopped working/)).not.toBeInTheDocument();
  });

  it("shows the banner on Birthdays only when a loaded birthday has a reminder on", async () => {
    go("#/birthdays");
    mount({ "GET /api/me": ME(NONE) });
    expect(await screen.findByText(/Reminders have nowhere to go yet\./)).toBeInTheDocument();
  });

  it("hides the Birthdays banner when no birthday has a reminder", async () => {
    go("#/birthdays");
    mount({ "GET /api/me": ME(NONE), "GET /api/birthdays": BIRTHDAYS([ADA, BOB]) });
    await screen.findByText("2 birthdays");
    expect(screen.queryByText(/nowhere to go/)).not.toBeInTheDocument();
  });
});

describe("detail and history", () => {
  it("opens a detail from a row with a pushed entry, and Back returns to the tab and focuses the row link", async () => {
    go("#/birthdays");
    const { user } = mount({
      "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }),
    });
    await user.click(await screen.findByRole("link", { name: "Ada Lovelace" }));
    expect(window.location.hash).toBe("#/b/2");
    expect(window.history.state).toEqual({ origin: "birthdays" });
    expect(await screen.findByRole("heading", { level: 2, name: "Ada Lovelace" })).toBeInTheDocument();
    expect(within(nav()).getByRole("link", { name: /Birthdays/ })).toHaveAttribute("aria-current", "page");
    const back = vi.spyOn(window.history, "back").mockImplementation(() => {
      window.history.replaceState(null, "", "#/birthdays");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    await user.click(backLink());
    expect(back).toHaveBeenCalled();
    await waitFor(() => expect(screen.getByRole("link", { name: "Ada Lovelace" })).toHaveFocus());
  });

  it("a detail opened from Add is labelled Add and marks the Add tab", async () => {
    go("#/add");
    const created = bd(9, "Mia Chen", 11, 21);
    const { user } = mount({
      "POST /api/birthdays": () => json(created, 201),
      "GET /api/birthdays/9": () => json({ birthday: created, shares: [], gifts: [] }),
    });
    await user.type(await nameField(), "Mia Chen");
    await user.click(month("November"));
    await user.type(dayInput(), "21");
    await user.click(addButton());
    await user.click(await screen.findByRole("link", { name: "Mia Chen" }));
    expect(window.history.state).toEqual({ origin: "add" });
    await screen.findByRole("heading", { level: 2, name: "Mia Chen" });
    expect(backLink()).toHaveTextContent("← Add");
    expect(within(nav()).getByRole("link", { name: /Add/ })).toHaveAttribute("aria-current", "page");
  });

  it("a direct visit to a detail, then the back link, replaces the entry with #/birthdays (no loop)", async () => {
    go("#/b/2");
    const { user } = mount({ "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }) });
    await screen.findByRole("heading", { level: 2, name: "Ada Lovelace" });
    const before = window.history.length;
    const push = vi.spyOn(window.history, "pushState");
    await user.click(backLink());
    expect(window.location.hash).toBe("#/birthdays");
    expect(push).not.toHaveBeenCalled();
    expect(window.history.length).toBe(before);
    expect(await screen.findByRole("heading", { level: 2, name: "Birthdays" })).toBeInTheDocument();
  });

  it("a modified click on a row link is left to the browser", async () => {
    go("#/birthdays");
    mount();
    const link = await screen.findByRole("link", { name: "Ada Lovelace" });
    const push = vi.spyOn(window.history, "pushState");
    fireEvent.click(link, { ctrlKey: true });
    fireEvent.click(link, { metaKey: true });
    expect(push).not.toHaveBeenCalled();
    // jsdom follows the plain hash link (the browser's job); let its hashchange land inside this test, not the next.
    await waitFor(() => expect(window.location.hash).toBe("#/b/2"));
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0));
    });
  });

  it("an unknown birthday shows Birthday not found with a plain link back", async () => {
    go("#/b/99");
    mount({ "GET /api/birthdays/99": () => json({ error: "not_found" }, 404) });
    expect(await screen.findByRole("heading", { level: 2, name: "Birthday not found" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Back to birthdays" })).toHaveAttribute("href", "#/birthdays");
  });

  it("a malformed id is not found without calling the API", async () => {
    go("#/b/abc");
    mount();
    expect(await screen.findByRole("heading", { level: 2, name: "Birthday not found" })).toBeInTheDocument();
    expect(calls.some((c) => c.key.startsWith("GET /api/birthdays/"))).toBe(false);
  });

  it("deleting needs a confirm, then replaces the entry with #/birthdays and announces it", async () => {
    go("#/b/2");
    const { user } = mount({
      "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }),
      "DELETE /api/birthdays/2": () => new Response(null, { status: 204 }),
    });
    await user.click(await screen.findByRole("button", { name: "Delete" }));
    expect(count("DELETE /api/birthdays/2")).toBe(0);
    expect(screen.getByText("Delete Ada Lovelace for everyone?")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Yes, delete" }));
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
    expect(screen.getByTestId("app-notice")).toHaveTextContent("Deleted Ada Lovelace.");
    expect(await screen.findByRole("heading", { level: 2, name: "Birthdays" })).toBeInTheDocument();
  });

  it("a shared birthday offers Remove from my list", async () => {
    go("#/b/3");
    const { user } = mount({
      "GET /api/birthdays/3": () => json({ birthday: ZED, gifts: [] }),
      "DELETE /api/birthdays/3": () => new Response(null, { status: 204 }),
    });
    await user.click(await screen.findByRole("button", { name: "Remove from my list" }));
    expect(screen.getByText("Remove Zed Young from your list?")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Yes, remove" }));
    await waitFor(() => expect(screen.getByTestId("app-notice")).toHaveTextContent("Removed Zed Young from your list."));
  });

  it("focuses the new screen's h2 after a tab change", async () => {
    go("#/birthdays");
    const { user } = mount();
    await screen.findByText("Sam turns 36");
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    await waitFor(() => expect(screen.getByRole("heading", { level: 2, name: "Add a birthday" })).toHaveFocus());
  });

  it("does not move focus on first load", async () => {
    go("#/birthdays");
    mount();
    await screen.findByText("Sam turns 36");
    expect(document.body).toHaveFocus();
  });
});

describe("palette", () => {
  it("applies the stored palette before the server answers, then the server value wins and is stored", async () => {
    window.localStorage.setItem("birthdays:palette", "candle");
    const d = deferred();
    mount({ "GET /api/me": () => d.promise });
    expect(document.documentElement.getAttribute("data-palette")).toBe("candle");
    await act(async () => {
      d.resolve(json({ email: EMAIL, settings: settings({ color_scheme: "frosting" }) }));
    });
    await waitFor(() => expect(document.documentElement.getAttribute("data-palette")).toBe("frosting"));
    expect(window.localStorage.getItem("birthdays:palette")).toBe("frosting");
  });

  it("ignores an unknown stored palette", async () => {
    window.localStorage.setItem("birthdays:palette", "neon");
    mount();
    await loaded();
    expect(window.localStorage.getItem("birthdays:palette")).toBe("confetti");
  });
});

describe("edge input", () => {
  it("renders names with markup and very long unbroken names as plain text", async () => {
    go("#/birthdays");
    const nasty = bd(7, "<img src=x onerror=alert(1)>", 11, 18);
    const long = bd(8, "W".repeat(200), 11, 19);
    mount({ "GET /api/birthdays": BIRTHDAYS([nasty, long]) });
    expect(await screen.findByText("<img src=x onerror=alert(1)>'s birthday", { selector: "a" })).toBeInTheDocument();
    expect(document.querySelector("img")).toBeNull();
    expect(screen.getByText("W".repeat(200), { selector: "a" })).toBeInTheDocument();
  });

  it("handles non-Latin and emoji names in avatars", async () => {
    go("#/birthdays");
    mount({
      "GET /api/birthdays": BIRTHDAYS([bd(7, "日本語", 11, 18), bd(8, "\u{1F600}", 11, 19)]),
    });
    await screen.findByRole("link", { name: /日本語/ });
    const avatars = Array.from(document.querySelectorAll(".avatar")).map((a) => a.textContent);
    expect(avatars).toContain("日");
    expect(avatars).toContain("\u{1F382}");
  });
});

describe("scroll and focus on route changes", () => {
  const detail2: Routes = { "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }) };

  it("a tab return restores the saved scroll and focuses the h2 with preventScroll; a fresh tab focuses plainly", async () => {
    go("#/birthdays");
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const scrollTo = vi.mocked(window.scrollTo);
    const { user } = mount();
    await screen.findByText("Sam turns 36");
    setScrollY(240);
    scrollTo.mockClear();
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    const addH = await screen.findByRole("heading", { level: 2, name: "Add a birthday" });
    await waitFor(() => expect(addH).toHaveFocus());
    expect(scrollTo).toHaveBeenLastCalledWith(0, 0);
    expect(focusArgs(focus, addH)).toEqual([undefined]);

    setScrollY(90);
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    const bdH = await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await waitFor(() => expect(bdH).toHaveFocus());
    expect(scrollTo).toHaveBeenLastCalledWith(0, 240);
    expect(focusArgs(focus, bdH)).toEqual([{ preventScroll: true }]);
  });

  it("browser Back and Forward (popstate then hashchange) restore scroll and focus the h2 once", async () => {
    go("#/birthdays");
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const scrollTo = vi.mocked(window.scrollTo);
    mount();
    await screen.findByText("Sam turns 36");
    setScrollY(240);
    await browserNavigate("#/add");
    const addH = await screen.findByRole("heading", { level: 2, name: "Add a birthday" });
    await waitFor(() => expect(addH).toHaveFocus());
    expect(focusArgs(focus, addH)).toEqual([undefined]);

    setScrollY(60);
    scrollTo.mockClear();
    await browserNavigate("#/birthdays");
    const bdH = await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await waitFor(() => expect(bdH).toHaveFocus());
    expect(scrollTo).toHaveBeenCalledTimes(1);
    expect(scrollTo).toHaveBeenCalledWith(0, 240);
    expect(focusArgs(focus, bdH)).toEqual([{ preventScroll: true }]);
  });

  it("Back from a detail restores the list scroll and focuses the originating link with preventScroll", async () => {
    go("#/birthdays");
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const scrollTo = vi.mocked(window.scrollTo);
    const { user } = mount(detail2);
    const row = await screen.findByRole("link", { name: "Ada Lovelace" });
    setScrollY(120);
    await user.click(row);
    await screen.findByRole("heading", { level: 2, name: "Ada Lovelace" });
    expect(scrollTo).toHaveBeenLastCalledWith(0, 0);
    setScrollY(0);
    await browserNavigate("#/birthdays");
    const again = await screen.findByRole("link", { name: "Ada Lovelace" });
    await waitFor(() => expect(again).toHaveFocus());
    expect(scrollTo).toHaveBeenLastCalledWith(0, 120);
    expect(focusArgs(focus, again)).toEqual([{ preventScroll: true }]);
  });

  it("opening a tab fresh from a detail focuses its h2 without preventScroll", async () => {
    go("#/b/2");
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    mount(detail2);
    await screen.findByRole("heading", { level: 2, name: "Ada Lovelace" });
    window.location.hash = "#/add";
    const addH = await screen.findByRole("heading", { level: 2, name: "Add a birthday" });
    await waitFor(() => expect(addH).toHaveFocus());
    expect(focusArgs(focus, addH)).toEqual([undefined]);
  });

  it("Delete from an Add-origin detail replaces the entry and focuses the Birthdays h2", async () => {
    go("#/add");
    const created = bd(9, "Mia Chen", 11, 21);
    const { user } = mount({
      "POST /api/birthdays": () => json(created, 201),
      "GET /api/birthdays/9": () => json({ birthday: created, shares: [], gifts: [] }),
      "DELETE /api/birthdays/9": () => new Response(null, { status: 204 }),
    });
    await user.type(await nameField(), "Mia Chen");
    await user.click(month("November"));
    await user.type(dayInput(), "21");
    await user.click(addButton());
    await user.click(await screen.findByRole("link", { name: "Mia Chen" }));
    expect(window.history.state).toEqual({ origin: "add" });
    await user.click(await screen.findByRole("button", { name: "Delete" }));
    await user.click(screen.getByRole("button", { name: "Yes, delete" }));
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
    expect(window.history.state).toBeNull();
    const bdH = await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await waitFor(() => expect(bdH).toHaveFocus());
    expect(within(nav()).getByRole("link", { name: /Birthdays/ })).toHaveAttribute("aria-current", "page");
    expect(screen.getByTestId("app-notice")).toHaveTextContent("Deleted Mia Chen.");
  });

  it("the delete confirm keeps focus: Cancel when it opens, Delete again on Cancel, and is a named group", async () => {
    go("#/b/2");
    const { user } = mount(detail2);
    await user.click(await screen.findByRole("button", { name: "Delete" }));
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
    expect(screen.getByRole("group", { name: "Delete Ada Lovelace for everyone?" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Delete" })).toHaveFocus());
  });
});

describe("tab bar and keyboard", () => {
  it("is not hidden by input focus alone when visualViewport is absent", async () => {
    go("#/add");
    const { user } = mount();
    await nameField();
    await user.click(nameInput());
    expect(nameInput()).toHaveFocus();
    expect(nav()).not.toHaveAttribute("data-kbd");
  });

  it("is not hidden by input focus or an unchanged viewport resize", async () => {
    const listeners: (() => void)[] = [];
    const vv = {
      height: window.innerHeight,
      addEventListener: (_: string, fn: () => void) => listeners.push(fn),
      removeEventListener: () => undefined,
    };
    Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
    go("#/add");
    const { user } = mount();
    await nameField();
    await user.click(nameInput());
    expect(nav()).not.toHaveAttribute("data-kbd");
    act(() => listeners.forEach((fn) => fn()));
    expect(nav()).not.toHaveAttribute("data-kbd");
  });
});

describe("Birthdays hero and view switcher", () => {
  it("the hero says Next up when nothing is today, with the week count", async () => {
    go("#/birthdays");
    mount({ "GET /api/birthdays": BIRTHDAYS([ADA, BOB]) });
    expect(await screen.findByText("Next up · Tomorrow")).toHaveClass("eyebrow");
    expect(screen.getByRole("link", { name: "Ada Lovelace's birthday" })).toHaveAttribute("href", "#/b/2");
    expect(screen.getByText("1 birthday in the next 7 days")).toBeInTheDocument();
  });

  it("the hero drops the week line when nothing falls in the next 7 days", async () => {
    go("#/birthdays");
    mount({ "GET /api/birthdays": BIRTHDAYS([BOB]) });
    expect(await screen.findByText(/^Next up · /)).toHaveClass("eyebrow");
    expect(screen.queryByText(/in the next 7 days/)).not.toBeInTheDocument();
  });

  it("the view radios stay disabled until /api/me has answered", async () => {
    go("#/birthdays");
    const me = deferred();
    mount({ "GET /api/me": () => me.promise });
    await screen.findByText("Sam turns 36");
    expect(screen.getByRole("radio", { name: "A–Z" })).toBeDisabled();
    await act(async () => {
      me.resolve(json({ email: EMAIL, settings: SETTINGS }));
    });
    await waitFor(() => expect(screen.getByRole("radio", { name: "A–Z" })).toBeEnabled());
  });

  it("an earlier PATCH response does not revert a newer pending view; Saved. only after the last PATCH", async () => {
    go("#/birthdays");
    const first = deferred();
    const second = deferred();
    let n = 0;
    const { user } = mount({ "PATCH /api/settings": () => (++n === 1 ? first.promise : second.promise) });
    await user.click(await viewRadio("A–Z"));
    await user.click(screen.getByRole("radio", { name: "By month" }));
    await act(async () => {
      first.resolve(json(settings({ list_view: "name" })));
    });
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(screen.getByRole("radio", { name: "By month" })).toBeChecked();
    expect(screen.getByTestId("view-status")).toHaveTextContent("Saving…");
    expect(screen.getByTestId("view-status")).not.toHaveTextContent("Saved.");
    await act(async () => {
      second.resolve(json(settings({ list_view: "month" })));
    });
    await waitFor(() => expect(screen.getByTestId("view-status")).toHaveTextContent("Saved."));
    expect(screen.getByRole("radio", { name: "By month" })).toBeChecked();
  });
});

describe("restored draft", () => {
  it("a restored draft whose checkbox was never touched still follows auto_remind", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: null }),
    );
    go("#/add");
    mount({ "GET /api/me": ME(settings({ auto_remind: true })) });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    await waitFor(() => expect(remindBox()).toBeChecked());
  });

  it("a restored draft keeps an explicit remind choice", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: false }),
    );
    go("#/add");
    mount({ "GET /api/me": ME(settings({ auto_remind: true })) });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(remindBox()).not.toBeChecked();
  });
});

type U = ReturnType<typeof userEvent.setup>;

const picker = () => screen.getByRole("group", { name: "When" });
const settingsPicker = () => screen.getByRole("group", { name: "Default timing" });
const inPicker = (name: string) => within(picker()).getByRole("checkbox", { name });
const chip = (text: string) => within(picker()).queryByText(text, { selector: "li" });
const remindOn = (over: Partial<Settings> = {}) => ME(settings({ auto_remind: true, default_offsets: [14, 7, 1], ...over }));

async function fillAdd(user: U) {
  await user.type(await nameField(), "Mia");
  await user.click(month("March"));
  await user.type(dayInput(), "5");
}
async function toTab(user: U, tab: RegExp, heading: string) {
  await user.click(within(nav()).getByRole("link", { name: tab }));
  await screen.findByRole("heading", { name: heading });
}
const toSettings = (user: U) => toTab(user, /Settings/, "Settings");
const toAdd = (user: U) => toTab(user, /Add/, "Add a birthday");

describe("Add timing picker", () => {
  it("prefills the picker from the defaults when Remind me is ticked and hides it when not", async () => {
    go("#/add");
    const { user } = mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(remindBox()).toBeChecked());
    expect(inPicker("1 day before")).toBeChecked();
    expect(inPicker("On the day")).not.toBeChecked();
    expect(chip("2 weeks")).toBeInTheDocument();
    expect(chip("1 week")).toBeInTheDocument();
    await fillAdd(user);
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [14, 7, 1] });
    await user.click(remindBox());
    expect(screen.queryByRole("group", { name: "When" })).not.toBeInTheDocument();
  });

  it("hides the picker and sends empty offsets with auto_remind off", async () => {
    go("#/add");
    const { user } = mount({ "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5), 201) });
    await fillAdd(user);
    expect(screen.queryByRole("group", { name: "When" })).not.toBeInTheDocument();
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [] });
  });

  it("a custom timing for one add becomes the default: next prefill and Settings show it, with no PATCH", async () => {
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn({ default_offsets: [1] }),
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5, { reminder_offsets: [28, 0] }), 201),
    });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.selectOptions(within(picker()).getByLabelText("Add weeks before"), "4");
    await user.click(within(picker()).getByRole("button", { name: "Add" }));
    await user.click(inPicker("On the day"));
    await user.click(inPicker("1 day before"));
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [28, 0] });
    await waitFor(() => expect(nameInput()).toHaveValue(""));
    expect(inPicker("On the day")).toBeChecked();
    expect(inPicker("1 day before")).not.toBeChecked();
    expect(chip("4 weeks")).toBeInTheDocument();
    await toSettings(user);
    expect(within(settingsPicker()).getByText("4 weeks", { selector: "li" })).toBeInTheDocument();
    expect(within(settingsPicker()).getByRole("checkbox", { name: "On the day" })).toBeChecked();
    expect(count("PATCH /api/settings")).toBe(0);
  });

  it("adopts the server's canonical reminder_offsets, not the array the client sent", async () => {
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn({ default_offsets: [7, 1] }),
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5, { reminder_offsets: [14, 7, 1] }), 201),
    });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [7, 1] });
    await waitFor(() => expect(chip("2 weeks")).toBeInTheDocument());
    await toSettings(user);
    expect(within(settingsPicker()).getByText("2 weeks", { selector: "li" })).toBeInTheDocument();
  });

  it("an add with reminders off leaves the default alone, even if the picker was changed", async () => {
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn(),
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5), 201),
    });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.selectOptions(within(picker()).getByLabelText("Add weeks before"), "4");
    await user.click(within(picker()).getByRole("button", { name: "Add" }));
    await user.click(remindBox());
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [] });
    await waitFor(() => expect(nameInput()).toHaveValue(""));
    expect(chip("4 weeks")).not.toBeInTheDocument();
    expect(chip("2 weeks")).toBeInTheDocument();
    expect(inPicker("1 day before")).toBeChecked();
  });

  it("an untouched picker follows a Settings default change; a touched one does not", async () => {
    go("#/settings");
    const { user } = mount({
      "GET /api/me": remindOn(),
      "PATCH /api/settings": (init) => json(settings({ auto_remind: true, ...JSON.parse(String(init?.body)) as Partial<Settings> })),
    });
    await user.click(within(await screen.findByRole("group", { name: "Default timing" })).getByRole("checkbox", { name: "1 day before" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    await toAdd(user);
    expect(inPicker("1 day before")).not.toBeChecked();
    await user.click(inPicker("On the day"));
    await toSettings(user);
    await user.click(within(settingsPicker()).getByRole("checkbox", { name: "1 day before" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    await toAdd(user);
    expect(inPicker("On the day")).toBeChecked();
    expect(inPicker("1 day before")).not.toBeChecked();
  });

  it("a restored draft keeps its offsets", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: true, offsets: [28] }),
    );
    go("#/add");
    mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(chip("4 weeks")).toBeInTheDocument();
    expect(chip("2 weeks")).not.toBeInTheDocument();
    expect(inPicker("1 day before")).not.toBeChecked();
  });

  it("an old-shape restored draft takes the defaults; a restored empty offsets list shows an empty picker", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: true }),
    );
    go("#/add");
    const first = mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(chip("2 weeks")).toBeInTheDocument();
    expect(inPicker("1 day before")).toBeChecked();
    first.unmount();
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: true, offsets: [] }),
    );
    const { user } = mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    expect(inPicker("1 day before")).not.toBeChecked();
    expect(chip("2 weeks")).not.toBeInTheDocument();
    await user.click(addButton());
    expect(count("POST /api/birthdays")).toBe(0);
    expect(screen.getByText("Pick at least one reminder time.")).toBeInTheDocument();
  });

  it("a restored touched value is sent, and the server's differing canonical offsets become the default", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: true, offsets: [28] }),
    );
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn(),
      "POST /api/birthdays": () => json(bd(9, "Kept", 4, 9, { reminder_offsets: [35, 0] }), 201),
    });
    await waitFor(() => expect(nameInput()).toHaveValue("Kept"));
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Kept", month: 4, day: 9, offsets: [28] });
    await waitFor(() => expect(chip("5 weeks")).toBeInTheDocument());
    expect(chip("4 weeks")).not.toBeInTheDocument();
    await toSettings(user);
    expect(within(settingsPicker()).getByText("5 weeks", { selector: "li" })).toBeInTheDocument();
  });

  it("a restored draft with non-canonical offsets is discarded, so the picker shows the defaults", async () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ who: draftTag(EMAIL), name: "Kept", month: 4, day: "9", year: "", remind: true, offsets: [1, 14] }),
    );
    go("#/add");
    mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(remindBox()).toBeChecked());
    expect(nameInput()).toHaveValue("");
    expect(chip("2 weeks")).toBeInTheDocument();
    expect(inPicker("1 day before")).toBeChecked();
  });

  it("Enter in the weeks select adds the week and never submits; Enter on a checkbox never submits", async () => {
    go("#/add");
    const post = vi.fn(() => json(bd(9, "Mia", 3, 5), 201));
    const { user } = mount({ "GET /api/me": remindOn(), "POST /api/birthdays": post });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    const select = within(picker()).getByLabelText("Add weeks before");
    expect(fireEvent.keyDown(select, { key: "Enter" })).toBe(false);
    expect(chip("4 weeks")).not.toBeInTheDocument();
    fireEvent.change(select, { target: { value: "4" } });
    expect(fireEvent.keyDown(select, { key: "Enter" })).toBe(false);
    expect(await within(picker()).findByText("4 weeks", { selector: "li" })).toBeInTheDocument();
    expect(fireEvent.keyDown(inPicker("On the day"), { key: "Enter" })).toBe(false);
    expect(post).not.toHaveBeenCalled();
  });

  it("an empty picker blocks the POST and shows its error beside the other field errors", async () => {
    go("#/add");
    const { user } = mount({ "GET /api/me": remindOn({ default_offsets: [1] }) });
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.click(inPicker("1 day before"));
    await user.click(addButton());
    expect(screen.getByText("Enter a name.")).toBeInTheDocument();
    expect(screen.getByText("Pick at least one reminder time.")).toBeInTheDocument();
    expect(nameInput()).toHaveFocus();
    await user.type(nameInput(), "Mia");
    await user.click(month("March"));
    await user.type(dayInput(), "5");
    await user.click(addButton());
    expect(count("POST /api/birthdays")).toBe(0);
    expect(screen.getByText("Pick at least one reminder time.")).toBeInTheDocument();
    expect(inPicker("On the day")).toHaveFocus();
    await user.click(inPicker("On the day"));
    expect(screen.queryByText("Pick at least one reminder time.")).not.toBeInTheDocument();
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [0] });
  });

  it("the picker error clears on unticking Remind me, and untick then re-tick keeps the chosen offsets", async () => {
    go("#/add");
    const { user } = mount({ "GET /api/me": remindOn({ default_offsets: [1] }) });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.click(inPicker("1 day before"));
    await user.click(addButton());
    expect(screen.getByText("Pick at least one reminder time.")).toBeInTheDocument();
    await user.click(remindBox());
    expect(screen.queryByText("Pick at least one reminder time.")).not.toBeInTheDocument();
    await user.click(remindBox());
    expect(screen.queryByText("Pick at least one reminder time.")).not.toBeInTheDocument();
    expect(inPicker("1 day before")).not.toBeChecked();
    await user.click(inPicker("On the day"));
    await user.click(remindBox());
    await user.click(remindBox());
    expect(inPicker("On the day")).toBeChecked();
  });

  it("a failed add keeps draft.offsets and leaves the default alone", async () => {
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn({ default_offsets: [7, 1] }),
      "POST /api/birthdays": () => json({ error: "internal" }, 500),
    });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.selectOptions(within(picker()).getByLabelText("Add weeks before"), "4");
    await user.click(within(picker()).getByRole("button", { name: "Add" }));
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(chip("4 weeks")).toBeInTheDocument();
    await toSettings(user);
    expect(within(settingsPicker()).queryByText("4 weeks", { selector: "li" })).not.toBeInTheDocument();
    await toAdd(user);
    expect(chip("4 weeks")).toBeInTheDocument();
  });

  it("a server invalid_offsets lands in the picker error, focuses the first checkbox and keeps the draft", async () => {
    go("#/add");
    const { user } = mount({
      "GET /api/me": remindOn(),
      "POST /api/birthdays": () => json({ error: "invalid_offsets" }, 400),
    });
    await fillAdd(user);
    await waitFor(() => expect(remindBox()).toBeChecked());
    await user.click(addButton());
    expect(await within(picker()).findByText("Pick at least one reminder time.")).toBeInTheDocument();
    expect(inPicker("On the day")).toHaveFocus();
    expect(within(screen.getByTestId("add-alert")).queryByText(/./)).not.toBeInTheDocument();
    expect(nameInput()).toHaveValue("Mia");
    expect(chip("2 weeks")).toBeInTheDocument();
    await toSettings(user);
    expect(within(settingsPicker()).getByText("2 weeks", { selector: "li" })).toBeInTheDocument();
  });

  it("states the hint and renders checkbox, picker, hint, then notice, with the described-by wiring", async () => {
    go("#/add");
    mount({ "GET /api/me": remindOn({ ntfy: false }) });
    await waitFor(() => expect(remindBox()).toBeChecked());
    const hint = screen.getByText(/A time that has already passed this year starts next year\./);
    expect(hint).toHaveTextContent("Sent at 7am Pacific. Your choice is kept for next time.");
    const notice = document.getElementById("add-remind-hint") as HTMLElement;
    const follows = (a: Element, b: Element) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
    expect(follows(remindBox(), picker())).toBe(true);
    expect(follows(picker(), hint)).toBe(true);
    expect(follows(hint, notice)).toBe(true);
    expect(picker()).toHaveAttribute("aria-describedby", "add-err add-timing-hint add-remind-hint");
    expect(remindBox()).toHaveAttribute("aria-describedby", "add-remind-hint");
  });

  it("describes the picker without the notice when a destination exists", async () => {
    go("#/add");
    mount({ "GET /api/me": remindOn() });
    await waitFor(() => expect(remindBox()).toBeChecked());
    expect(picker()).toHaveAttribute("aria-describedby", "add-err add-timing-hint");
    expect(remindBox()).not.toHaveAttribute("aria-describedby");
  });

  it("an in-flight list_view PATCH carrying the old default never overwrites an adopted default", async () => {
    go("#/birthdays");
    const held = deferred();
    const { user } = mount({
      "GET /api/me": remindOn({ default_offsets: [7, 1] }),
      "PATCH /api/settings": () => held.promise,
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5, { reminder_offsets: [28, 0] }), 201),
    });
    await user.click(await viewRadio("A–Z"));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    await toAdd(user);
    await fillAdd(user);
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    await waitFor(() => expect(chip("4 weeks")).toBeInTheDocument());
    await act(async () => {
      held.resolve(json(settings({ auto_remind: true, list_view: "name", default_offsets: [7, 1] })));
    });
    await toSettings(user);
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Saved."));
    expect(within(settingsPicker()).getByText("4 weeks", { selector: "li" })).toBeInTheDocument();
    expect(within(settingsPicker()).queryByText("1 week", { selector: "li" })).not.toBeInTheDocument();
    await toAdd(user);
    expect(chip("4 weeks")).toBeInTheDocument();
  });

  it("a Settings default PATCH in flight or queued is not overridden by the add's local default update", async () => {
    go("#/settings");
    const first = deferred();
    const second = deferred();
    let n = 0;
    const { user } = mount({
      "GET /api/me": remindOn(),
      "PATCH /api/settings": () => (++n === 1 ? first.promise : second.promise),
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5, { reminder_offsets: [28] }), 201),
    });
    await screen.findByRole("group", { name: "Default timing" });
    await user.click(within(settingsPicker()).getByRole("checkbox", { name: "1 day before" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    await user.click(within(settingsPicker()).getByRole("checkbox", { name: "On the day" }));
    await toAdd(user);
    await fillAdd(user);
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    expect(bodyOf("POST /api/birthdays")).toEqual({ name: "Mia", month: 3, day: 5, offsets: [14, 7, 0] });
    await waitFor(() => expect(nameInput()).toHaveValue(""));
    expect(chip("4 weeks")).not.toBeInTheDocument();
    expect(inPicker("On the day")).toBeChecked();
    await toSettings(user);
    expect(within(settingsPicker()).queryByText("4 weeks", { selector: "li" })).not.toBeInTheDocument();
    expect(within(settingsPicker()).getByRole("checkbox", { name: "On the day" })).toBeChecked();
    await act(async () => {
      first.resolve(json(settings({ auto_remind: true, default_offsets: [14, 7] })));
    });
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(bodyOf("PATCH /api/settings", 0)).toEqual({ default_offsets: [14, 7] });
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ default_offsets: [14, 7, 0] });
    await act(async () => {
      second.resolve(json(settings({ auto_remind: true, default_offsets: [14, 7, 0] })));
    });
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Saved."));
    expect(within(settingsPicker()).getByRole("checkbox", { name: "On the day" })).toBeChecked();
    expect(within(settingsPicker()).getByRole("checkbox", { name: "1 day before" })).not.toBeChecked();
  });

  it("after a failed Settings default PATCH, a successful add applies the POST value and clears the failure line", async () => {
    go("#/settings");
    const { user } = mount({
      "GET /api/me": remindOn(),
      "PATCH /api/settings": () => json({ error: "internal" }, 500),
      "POST /api/birthdays": () => json(bd(9, "Mia", 3, 5, { reminder_offsets: [28, 0] }), 201),
    });
    await screen.findByRole("group", { name: "Default timing" });
    await user.click(within(settingsPicker()).getByRole("checkbox", { name: "1 day before" }));
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Couldn't save that"));
    await toAdd(user);
    await fillAdd(user);
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/birthdays")).toBe(1));
    await waitFor(() => expect(chip("4 weeks")).toBeInTheDocument());
    await toSettings(user);
    expect(within(settingsPicker()).getByText("4 weeks", { selector: "li" })).toBeInTheDocument();
    expect(within(settingsPicker()).getByRole("checkbox", { name: "On the day" })).toBeChecked();
    expect(screen.getByTestId("settings-status")).not.toHaveTextContent("Couldn't save that");
  });
});

describe("grouping helpers", () => {
  it("letterOf ignores case and accents and buckets non-letters to #", () => {
    expect(letterOf("élodie")).toBe("E");
    expect(letterOf("Élodie")).toBe("E");
    expect(letterOf("1st")).toBe("#");
    expect(letterOf("\u{1F600}")).toBe("#");
    expect(letterOf("")).toBe("#");
  });

  it("groupByLetter sorts within a letter, case-insensitively", () => {
    const g = groupByLetter(withDates([bd(1, "bob", 1, 1), bd(2, "Bea", 1, 2), bd(3, "Ann", 1, 3)], TODAY));
    expect(g.map((x) => x.letter)).toEqual(["A", "B"]);
    expect(g[1]?.items.map((d) => d.b.name)).toEqual(["Bea", "bob"]);
  });

  it("groupByMonth orders by day then name and skips empty months", () => {
    const g = groupByMonth(withDates([bd(1, "B", 5, 2), bd(2, "A", 5, 2), bd(3, "C", 5, 1), bd(4, "D", 2, 9)], TODAY));
    expect(g.map((x) => x.month)).toEqual([2, 5]);
    expect(g[1]?.items.map((d) => d.b.name)).toEqual(["C", "A", "B"]);
  });
});

describe("Calendar view", () => {
  const LEAP = bd(7, "Leap Day", 2, 29, { year: 2000 });

  // PATCH /api/settings echoes the saved fields back on top of a calendar-view person.
  const patchEcho: Handler = (init) =>
    json(settings({ list_view: "calendar", ...(JSON.parse(String(init?.body)) as Partial<Settings>) }));

  function mountCalendar(list: Birthday[] = LIST, zoom: Settings["calendar_zoom"] = "month") {
    go("#/birthdays");
    return mount({
      "GET /api/me": ME(settings({ list_view: "calendar", calendar_zoom: zoom })),
      "GET /api/birthdays": BIRTHDAYS(list),
      "PATCH /api/settings": patchEcho,
      "GET /api/birthdays/3": () => json({ birthday: ZED, shares: null, gifts: [] }),
    });
  }

  const zoomRadio = async (name: string) => {
    const radio = await screen.findByRole("radio", { name });
    await waitFor(() => expect(radio).toBeEnabled());
    return radio;
  };
  const heading = (name: string) => screen.getByRole("heading", { level: 3, name });
  const dayButton = (name: string | RegExp) => screen.getByRole("button", { name });

  it("shows the zoom switcher only with Calendar selected", async () => {
    go("#/birthdays");
    const { user } = mount();
    await user.click(await viewRadio("By month"));
    expect(screen.queryByRole("radio", { name: "Week" })).not.toBeInTheDocument();
    await user.click(screen.getByRole("radio", { name: "Calendar" }));
    expect(screen.getByRole("radio", { name: "Week" })).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "Year" })).toBeInTheDocument();
    await user.click(screen.getByRole("radio", { name: "A–Z" }));
    expect(screen.queryByRole("radio", { name: "Week" })).not.toBeInTheDocument();
  });

  it("lays out November 2026: starts on Sunday, 30 days, caption, abbreviated weekdays, today marked", async () => {
    mountCalendar();
    const table = await screen.findByRole("table", { name: "November 2026" });
    expect(within(table).getAllByRole("columnheader").map((h) => h.textContent)).toEqual([
      "Sun",
      "Mon",
      "Tue",
      "Wed",
      "Thu",
      "Fri",
      "Sat",
    ]);
    const days = within(table).getAllByRole("button");
    expect(days).toHaveLength(30);
    const firstRow = table.querySelector("tbody tr") as HTMLElement;
    expect(firstRow.querySelectorAll("td")[0]?.querySelector("button")).toHaveAttribute("data-date", "2026-11-01");
    expect(within(table).getByRole("button", { name: "November 16, today, 1 birthday" }).closest("td")).toHaveClass("today");
    expect(within(table).getByRole("button", { name: "November 17, 1 birthday" })).toBeInTheDocument();
    expect(within(table).getByRole("button", { name: "November 3" })).toBeInTheDocument();
    expect(heading("November 2026")).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "Month" })).toBeChecked();
  });

  it("selects today by default and lists its birthdays under the grid with the standard row", async () => {
    mountCalendar();
    expect(await screen.findByRole("button", { name: /^November 16/ })).toHaveAttribute("aria-pressed", "true");
    expect(dayButton("November 17, 1 birthday")).toHaveAttribute("aria-pressed", "false");
    const line = heading("Monday, November 16").parentElement as HTMLElement;
    const row = within(line).getByRole("link", { name: "Sam Rivera" }).closest("li") as HTMLElement;
    expect(row).toHaveTextContent("Mon, Nov 16 · turns 36");
    expect(within(row).getByText("Today")).toHaveClass("chip");
  });

  it("renders names as links inside the day cell (chips) and a dot for the phone layout", async () => {
    mountCalendar();
    const cell = (await screen.findByRole("button", { name: "November 20, 1 birthday" })).closest("td") as HTMLElement;
    const chip = within(cell).getByRole("link", { name: "Zed Young" });
    expect(chip).toHaveAttribute("href", "#/b/3");
    expect(chip.className).toMatch(/tint\d/);
    expect(cell.querySelector(".dot")).toHaveAttribute("aria-hidden", "true");
  });

  it("selecting a day lists its people, announces it, and shows the empty line for a quiet day", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "November 20, 1 birthday" }));
    expect(dayButton("November 20, 1 birthday")).toHaveAttribute("aria-pressed", "true");
    expect(dayButton(/^November 16/)).toHaveAttribute("aria-pressed", "false");
    expect(screen.getByTestId("day-status")).toHaveTextContent("November 20 - 1 birthday");
    const line = heading("Friday, November 20").parentElement as HTMLElement;
    expect(within(line).getByRole("link", { name: "Zed Young" })).toBeInTheDocument();
    expect(line).toHaveTextContent("from pat");
    await user.click(dayButton("November 3"));
    expect(screen.getByTestId("day-status")).toHaveTextContent("November 3 - 0 birthdays");
    expect(screen.getByText("No birthdays on this day.")).toBeInTheDocument();
  });

  it("another month shows the tap prompt, keeps focus on Next, and Today resets", async () => {
    const { user } = mountCalendar();
    const next = await screen.findByRole("button", { name: "Next month" });
    await user.click(next);
    expect(heading("December 2026")).toBeInTheDocument();
    expect(screen.getByText("Tap a day to see its birthdays.")).toBeInTheDocument();
    expect(next).toHaveFocus();
    expect(dayButton("December 25, 1 birthday")).toBeInTheDocument();
    await user.click(next);
    expect(heading("January 2027")).toBeInTheDocument();
    const today = screen.getByRole("button", { name: "Today" });
    await user.click(today);
    expect(heading("November 2026")).toBeInTheDocument();
    expect(today).toHaveFocus();
    const prev = screen.getByRole("button", { name: "Previous month" });
    await user.click(prev);
    expect(heading("October 2026")).toBeInTheDocument();
    expect(prev).toHaveFocus();
  });

  // jsdom applies no media rules: the 40rem name/dot switch and the 44px touch targets are CSS-only and are checked
  // by hand in Step 13, not by these tests.

  it("Year view: a Feb 29 birthday counts in February and marks Feb 28 in a common year, then opens that month", async () => {
    const { user } = mountCalendar([...LIST, LEAP], "year");
    await user.click(await screen.findByRole("button", { name: "Next year" }));
    expect(heading("2027")).toBeInTheDocument();
    const feb = screen.getByRole("button", { name: "February, 1 birthday. Open month" });
    const mini = feb.closest(".mini") as HTMLElement;
    expect(mini.querySelector('td[data-date="2027-02-28"]')).toHaveClass("has");
    expect(mini.querySelectorAll("td[data-date]")).toHaveLength(28);
    await user.click(feb);
    expect(heading("February 2027")).toBeInTheDocument();
    const cell = dayButton("February 28, 1 birthday").closest("td") as HTMLElement;
    expect(within(cell).getByRole("link", { name: "Leap Day" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^February 29/ })).not.toBeInTheDocument();
  });

  it("Month grid: a Feb 29 birthday sits on Feb 29 in a leap year", async () => {
    const { user } = mountCalendar([...LIST, LEAP], "year");
    const next = await screen.findByRole("button", { name: "Next year" });
    await user.click(next);
    await user.click(next);
    await user.click(screen.getByRole("button", { name: "February, 1 birthday. Open month" }));
    expect(heading("February 2028")).toBeInTheDocument();
    expect(dayButton("February 29, 1 birthday")).toBeInTheDocument();
    expect(dayButton("February 28")).toBeInTheDocument();
  });

  it("Year view: a day that is both today and a birthday carries both classes", async () => {
    mountCalendar(LIST, "year");
    await screen.findByRole("button", { name: "November, 3 birthdays. Open month" });
    expect(document.querySelector('table.minical td[data-date="2026-11-16"]')).toHaveClass("today", "has");
  });

  it("zoom radios move focus to the new period heading for Month and Week", async () => {
    const { user } = mountCalendar(LIST, "year");
    await user.click(await zoomRadio("Month"));
    expect(heading("November 2026")).toHaveFocus();
    await user.click(await zoomRadio("Week"));
    expect(heading("Nov 15 – 21, 2026")).toHaveFocus();
  });

  it("Previous and Today keep focus on the pressed button", async () => {
    const { user } = mountCalendar();
    const prev = await screen.findByRole("button", { name: "Previous month" });
    await user.click(prev);
    expect(heading("October 2026")).toBeInTheDocument();
    expect(prev).toHaveFocus();
    const today = screen.getByRole("button", { name: "Today" });
    await user.click(today);
    expect(heading("November 2026")).toBeInTheDocument();
    expect(today).toHaveFocus();
  });

  it("Year zoom: PATCHes once, focuses the heading, marks birthday days and today, labels each month button", async () => {
    const { user } = mountCalendar();
    await user.click(await zoomRadio("Year"));
    expect(heading("2026")).toHaveFocus();
    await waitFor(() => expect(screen.getByTestId("view-status")).toHaveTextContent("Saved."));
    expect(bodyOf("PATCH /api/settings")).toEqual({ calendar_zoom: "year" });
    expect(count("PATCH /api/settings")).toBe(1);
    expect(screen.getAllByRole("button", { name: /Open month$/ })).toHaveLength(12);
    expect(screen.getByRole("button", { name: "March, 1 birthday. Open month" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "November, 3 birthdays. Open month" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "January, 0 birthdays. Open month" })).toBeInTheDocument();
    const minis = document.querySelectorAll("table.minical");
    expect(minis).toHaveLength(12);
    minis.forEach((t) => expect(t).toHaveAttribute("aria-hidden", "true"));
    const nov = minis[10] as HTMLElement;
    expect(nov.querySelector('td[data-date="2026-11-16"]')).toHaveClass("today");
    expect(nov.querySelector('td[data-date="2026-11-17"]')).toHaveClass("has");
    expect(nov.querySelector('td[data-date="2026-11-18"]')).not.toHaveClass("has");
    expect(nov.querySelectorAll("td[data-date]")).toHaveLength(30);
  });

  it("Year -> Month drill-down: opens the month, focuses its heading, PATCHes month, today is the anchor in its month", async () => {
    const { user } = mountCalendar(LIST, "year");
    await user.click(await screen.findByRole("button", { name: "March, 1 birthday. Open month" }));
    expect(heading("March 2026")).toHaveFocus();
    expect(screen.getByRole("radio", { name: "Month" })).toBeChecked();
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    expect(bodyOf("PATCH /api/settings")).toEqual({ calendar_zoom: "month" });
    expect(screen.getByText("Tap a day to see its birthdays.")).toBeInTheDocument();
    await user.click(await zoomRadio("Year"));
    await user.click(screen.getByRole("button", { name: /^November, .* Open month$/ }));
    expect(heading("November 2026")).toHaveFocus();
    expect(dayButton(/^November 16/)).toHaveAttribute("aria-pressed", "true");
  });

  it("Week zoom: seven Sunday-Saturday rows with people as links, a Today pill and 'No birthdays'", async () => {
    const { user } = mountCalendar();
    await user.click(await zoomRadio("Week"));
    expect(heading("Nov 15 – 21, 2026")).toHaveFocus();
    const rows = Array.from(document.querySelectorAll<HTMLElement>("ul.week > li"));
    expect(rows.map((r) => r.dataset.date)).toEqual([
      "2026-11-15",
      "2026-11-16",
      "2026-11-17",
      "2026-11-18",
      "2026-11-19",
      "2026-11-20",
      "2026-11-21",
    ]);
    expect(rows[0]).toHaveTextContent("Sun 15");
    expect(rows[0]).toHaveTextContent("No birthdays");
    expect(within(rows[1] as HTMLElement).getByText("Today")).toBeInTheDocument();
    const sam = within(rows[1] as HTMLElement).getByRole("link", { name: "Sam Rivera" });
    expect(sam).toHaveAttribute("href", "#/b/1");
    expect(rows[1]).toHaveTextContent("turns 36");
    expect(rows[5]).toHaveTextContent("shared by pat");
    expect(screen.getAllByText("No birthdays")).toHaveLength(4);
    expect(bodyOf("PATCH /api/settings")).toEqual({ calendar_zoom: "week" });
  });

  it("Feb 29 shows on Feb 28 in a week row", async () => {
    const { user } = mountCalendar([...LIST, LEAP], "year");
    await user.click(await screen.findByRole("button", { name: "Next year" }));
    await user.click(screen.getByRole("button", { name: "February, 1 birthday. Open month" }));
    await user.click(dayButton("February 28, 1 birthday"));
    await user.click(await zoomRadio("Week"));
    expect(heading("Feb 28 – Mar 6, 2027")).toBeInTheDocument();
    const row = document.querySelector('ul.week > li[data-date="2027-02-28"]') as HTMLElement;
    expect(within(row).getByRole("link", { name: "Leap Day" })).toBeInTheDocument();
    expect(row).toHaveTextContent("born Feb 29");
    expect(row).toHaveTextContent("turns 27");
  });

  it("a week straddling New Year shows a Jan 1 birthday in the next year's cell", async () => {
    const { user } = mountCalendar([...LIST, bd(8, "New Year", 1, 1)]);
    await user.click(await screen.findByRole("button", { name: "Next month" }));
    await user.click(dayButton("December 31"));
    await user.click(await zoomRadio("Week"));
    expect(heading("Dec 27 – Jan 2, 2027")).toBeInTheDocument();
    const row = document.querySelector('ul.week > li[data-date="2027-01-01"]') as HTMLElement;
    expect(within(row).getByRole("link", { name: "New Year" })).toBeInTheDocument();
    const dec = document.querySelector('ul.week > li[data-date="2026-12-27"]') as HTMLElement;
    expect(dec).toHaveTextContent("No birthdays");
  });

  it("Month -> Week -> Month stays in December when today is in another month", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "Next month" }));
    await user.click(await zoomRadio("Week"));
    expect(heading("Nov 29 – Dec 5, 2026")).toBeInTheDocument();
    await user.click(await zoomRadio("Month"));
    expect(heading("December 2026")).toBeInTheDocument();
  });

  it("keeps one anchor across zooms: Month -> Week -> Month with a week spanning two months", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "November 30" }));
    await user.click(await zoomRadio("Week"));
    expect(heading("Nov 29 – Dec 5, 2026")).toHaveFocus();
    await user.click(await zoomRadio("Month"));
    expect(heading("November 2026")).toHaveFocus();
    expect(dayButton("November 30")).toHaveAttribute("aria-pressed", "true");
  });

  it("Month -> Year -> Month keeps the year and month, and Previous/Next then a zoom change anchors on the new period", async () => {
    const { user } = mountCalendar();
    await user.click(await zoomRadio("Year"));
    await user.click(await zoomRadio("Month"));
    expect(heading("November 2026")).toBeInTheDocument();
    expect(dayButton(/^November 16/)).toHaveAttribute("aria-pressed", "true");
    await user.click(screen.getByRole("button", { name: "Next month" }));
    await user.click(await zoomRadio("Week"));
    expect(heading("Nov 29 – Dec 5, 2026")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Next week" }));
    await user.click(await zoomRadio("Year"));
    expect(heading("2026")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Next year" }));
    await user.click(await zoomRadio("Month"));
    expect(heading("January 2027")).toBeInTheDocument();
  });

  it("PATCHes only on zoom change, never for navigation or day selection", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "Next month" }));
    await user.click(dayButton("December 25, 1 birthday"));
    await user.click(screen.getByRole("button", { name: "Today" }));
    expect(count("PATCH /api/settings")).toBe(0);
    await user.click(await zoomRadio("Week"));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
  });

  it("keeps the period and selected day across a detail round trip and a tab change", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "November 20, 1 birthday" }));
    await user.click(within(heading("Friday, November 20").parentElement as HTMLElement).getByRole("link", { name: "Zed Young" }));
    expect(window.location.hash).toBe("#/b/3");
    const back = vi.spyOn(window.history, "back").mockImplementation(() => {
      window.history.replaceState(null, "", "#/birthdays");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    await screen.findByRole("heading", { level: 2, name: "Zed Young" });
    await user.click(backLink());
    expect(back).toHaveBeenCalled();
    expect(await screen.findByRole("button", { name: "November 20, 1 birthday" })).toHaveAttribute("aria-pressed", "true");
    await user.click(screen.getByRole("button", { name: "Next month" }));
    await user.click(within(nav()).getByRole("link", { name: /Settings/ }));
    await screen.findByRole("heading", { level: 2, name: "Settings" });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    expect(await screen.findByRole("heading", { level: 3, name: "December 2026" })).toBeInTheDocument();
  });

  it("keeps the selected day across a Settings tab round trip", async () => {
    const { user } = mountCalendar();
    await user.click(await screen.findByRole("button", { name: "November 20, 1 birthday" }));
    await user.click(within(nav()).getByRole("link", { name: /Settings/ }));
    await screen.findByRole("heading", { level: 2, name: "Settings" });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    expect(await screen.findByRole("button", { name: "November 20, 1 birthday" })).toHaveAttribute("aria-pressed", "true");
    expect(heading("November 2026")).toBeInTheDocument();
  });

  it("an empty list shows the empty state instead of a calendar", async () => {
    mountCalendar([]);
    expect(await screen.findByText("No birthdays yet.")).toBeInTheDocument();
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
  });
});
