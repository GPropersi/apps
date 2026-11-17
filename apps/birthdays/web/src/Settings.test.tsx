import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { Birthday, Destination, Settings } from "./api";

type Handler = (init?: RequestInit) => Response | Promise<Response>;
type Routes = Record<string, Handler>;

const JSON_CT = { "Content-Type": "application/json" };
const EMAIL = "alex@example.com";
const NTFY_PASSWORD = "7kq2-mx9d-p4tw-a8ne";
const HOOK_SECRET = "q3V8n0cXn1Zl2m6yT7bR4uJk9sEwHd5aPfGoLiYtC-A";
const HOOK_SECRET_2 = "Zz9y8x7w6v5u4t3s2r1q0pOnMlKjIhGfEdCbAaB1c2D";
const SETUP_URL = "https://ntfy.example.test/setup/abc";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_CT });
}
function html(status: number): Response {
  return new Response("<html>edge</html>", { status, headers: { "Content-Type": "text/html" } });
}
function deferred() {
  let resolve!: (r: Response | Promise<Response>) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const BASE: Settings = {
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
  return { ...BASE, ...over };
}

function bd(id: number, name: string, over: Partial<Birthday> = {}): Birthday {
  return { id, name, month: 11, day: 20, year: null, is_mine: true, owner_email: EMAIL, reminder_offsets: [], ...over };
}
const SAM = bd(1, "Sam Rivera", { reminder_offsets: [7, 1] });
const ADA = bd(2, "Ada Lovelace");

const D_OK: Destination = { id: 5, kind: "discord", label: "family-server", hint: "Webhook ending …k3Q", stale: false };
const D_STALE: Destination = { id: 6, kind: "webhook", label: "old-server", hint: "Webhook ending …x9Z", stale: true };

let calls: { key: string; body: unknown }[] = [];

function mount(routes: Routes = {}, s: Settings = BASE, list: Birthday[] = [SAM, ADA]) {
  calls = [];
  const table: Routes = {
    "GET /api/me": () => json({ email: EMAIL, settings: s }),
    "GET /api/birthdays": () => json({ birthdays: list }),
    "GET /api/notify/destinations": () => json({ destinations: [] }),
    ...routes,
  };
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
function go(hash: string) {
  window.history.replaceState(null, "", hash);
}

const nav = () => screen.getByRole("navigation", { name: "Main" });
const destStatus = () => screen.getByTestId("destinations-status");
const confirms = () => screen.queryAllByRole("group").filter((el) => el.classList.contains("confirm"));
const root = () => document.documentElement;

// The form's controls stay disabled until GET /api/me has answered.
async function ready() {
  const radio = await screen.findByRole("radio", { name: "Confetti" });
  await waitFor(() => expect(radio).toBeEnabled());
  await waitFor(() => expect(screen.getByLabelText(/^Label/)).toBeEnabled());
  await waitFor(() => expect(screen.getByLabelText(/webhook URL/i)).toBeEnabled());
}

const fieldErr = (id: "dest-label-err" | "dest-url-err") => document.getElementById(id);
const NO_PROMISE = /prompt|will (ask|warn|confirm)|before (closing|you close)/i;
const secretSections = () => Array.from(document.querySelectorAll("section[data-secret]"));
const NTFY_REGION = "Your phone notification password";
const HOOK_REGION = (label: string) => `Signing secret for webhook: ${label}`;

// Visit the Birthdays tab and wait for a name, so the app-level list is known to be loaded; then come back.
async function loadListThenSettings(user: ReturnType<typeof userEvent.setup>, name: string) {
  await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
  await screen.findAllByText(new RegExp(name));
  await user.click(within(nav()).getByRole("link", { name: /Settings/ }));
  await screen.findByLabelText("Birthdays view");
}

async function open(routes: Routes = {}, s: Settings = BASE, list?: Birthday[]) {
  go("#/settings");
  const m = mount(routes, s, list);
  await ready();
  return m;
}

async function fillAdd(user: ReturnType<typeof userEvent.setup>, label: string, url: string) {
  await user.type(screen.getByLabelText(/^Label/), label);
  await user.type(screen.getByLabelText(/webhook URL/i), url);
  await user.click(screen.getByRole("button", { name: "Add" }));
}

const WEBHOOK_CREATED = (id: number, label: string, secret: string | null, over: Partial<Settings> = {}): Handler => () =>
  json(
    {
      destination: { id, kind: "webhook", label, hint: "Webhook ending …abc", stale: false },
      ...(secret === null ? {} : { signing_secret: secret }),
      settings: settings({ destinations: 1, ...over }),
    },
    201,
  );

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2026, 10, 16, 12, 0, 0));
  window.sessionStorage.clear();
  window.localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  window.sessionStorage.clear();
  window.localStorage.clear();
  window.history.replaceState(null, "", "#/");
  root().removeAttribute("data-palette");
});

describe("app preferences", () => {
  it("picking a scheme applies data-palette at once, stores it and PATCHes once", async () => {
    const { user } = await open({ "PATCH /api/settings": (init) => json(settings(JSON.parse(String(init?.body)) as Partial<Settings>)) });
    expect(screen.getByRole("radio", { name: "Confetti" })).toBeChecked();
    expect(screen.getByText("Light or dark follows your device.")).toBeInTheDocument();
    await user.click(screen.getByRole("radio", { name: "Frosting" }));
    expect(root().getAttribute("data-palette")).toBe("frosting");
    expect(window.localStorage.getItem("birthdays:palette")).toBe("frosting");
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Saved."));
    expect(count("PATCH /api/settings")).toBe(1);
    expect(bodyOf("PATCH /api/settings")).toEqual({ color_scheme: "frosting" });
  });

  it("keeps the new scheme for this visit when the save fails and shows a quiet status", async () => {
    const { user } = await open({ "PATCH /api/settings": () => json({ error: "internal" }, 500) });
    await user.click(screen.getByRole("radio", { name: "Candlelight" }));
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Couldn't save that"));
    expect(root().getAttribute("data-palette")).toBe("candle");
    expect(screen.getByRole("radio", { name: "Candlelight" })).toBeChecked();
  });

  it("arrow keys on the scheme radios keep one PATCH in flight and end on the last value", async () => {
    const first = deferred();
    let n = 0;
    const { user } = await open({
      "PATCH /api/settings": (init) => (++n === 1 ? first.promise : json(settings(JSON.parse(String(init?.body)) as Partial<Settings>))),
    });
    screen.getByRole("radio", { name: "Confetti" }).focus();
    await user.keyboard("{ArrowRight}{ArrowRight}");
    expect(screen.getByRole("radio", { name: "Candlelight" })).toBeChecked();
    expect(count("PATCH /api/settings")).toBe(1);
    await act(async () => {
      first.resolve(json(settings({ color_scheme: "frosting" })));
    });
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ color_scheme: "candle" });
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Saved."));
    expect(root().getAttribute("data-palette")).toBe("candle");
  });

  it("start-tab radios PATCH and the choice applies on the next load", async () => {
    const { user } = await open({ "PATCH /api/settings": () => json(settings({ start_tab: "add" })) });
    await user.click(screen.getByRole("radio", { name: "Always Add" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    expect(bodyOf("PATCH /api/settings")).toEqual({ start_tab: "add" });
    expect(screen.getByRole("radio", { name: "Always Add" })).toBeChecked();
  });

  it("the view select and the Birthdays switcher stay in sync", async () => {
    const { user } = await open({
      "PATCH /api/settings": (init) => json(settings(JSON.parse(String(init?.body)) as Partial<Settings>)),
    });
    await user.selectOptions(screen.getByLabelText("Birthdays view"), "month");
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    const switcher = await screen.findByRole("radio", { name: "By month" });
    expect(switcher).toBeChecked();
    await user.click(screen.getByRole("radio", { name: "A–Z" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ list_view: "name" });
    await user.click(within(nav()).getByRole("link", { name: /Settings/ }));
    expect(await screen.findByLabelText("Birthdays view")).toHaveValue("name");
  });

  it("the calendar zoom select PATCHes", async () => {
    const { user } = await open({ "PATCH /api/settings": () => json(settings({ calendar_zoom: "week" })) });
    await user.selectOptions(screen.getByLabelText("Calendar zoom"), "week");
    await waitFor(() => expect(bodyOf("PATCH /api/settings")).toEqual({ calendar_zoom: "week" }));
  });
});

describe("reminder defaults", () => {
  it("saves the remind-on-add toggle and default timing through the shared helper", async () => {
    const { user } = await open({
      "PATCH /api/settings": (init) => json(settings(JSON.parse(String(init?.body)) as Partial<Settings>)),
    });
    await user.click(screen.getByRole("checkbox", { name: "Turn reminders on when I add a birthday" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(1));
    expect(bodyOf("PATCH /api/settings")).toEqual({ auto_remind: true });
    await user.click(screen.getByRole("checkbox", { name: "On the day" }));
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ default_offsets: [7, 1, 0] });
  });

  it("refuses to untick the last timing with an inline message and no PATCH", async () => {
    const { user } = await open({}, settings({ default_offsets: [1] }));
    await user.click(screen.getByRole("checkbox", { name: "1 day before" }));
    expect(document.getElementById("dt-err")).toHaveTextContent("Pick at least one reminder time.");
    expect(screen.getByRole("checkbox", { name: "1 day before" })).toBeChecked();
    expect(count("PATCH /api/settings")).toBe(0);
  });

  it("evaluates the last-box rule against the helper's latest value, not the rendered one", async () => {
    const first = deferred();
    const { user } = await open({ "PATCH /api/settings": () => first.promise });
    const week = screen.getByRole("checkbox", { name: "1 week before" });
    const day = screen.getByRole("checkbox", { name: "1 day before" });
    // Both clicks land before React re-renders in between.
    act(() => {
      fireEvent.click(week);
      fireEvent.click(day);
    });
    const bodies = calls.filter((c) => c.key === "PATCH /api/settings").map((c) => c.body);
    expect(bodies).toEqual([{ default_offsets: [1] }]);
    expect(document.getElementById("dt-err")).toHaveTextContent("Pick at least one reminder time.");
    await act(async () => {
      first.resolve(json(settings({ default_offsets: [1] })));
    });
    await user.click(screen.getByRole("checkbox", { name: "1 day before" }));
    expect(count("PATCH /api/settings")).toBe(1);
  });

  it("rapid default-timing ticks keep one PATCH in flight and then send the merged latest value", async () => {
    const first = deferred();
    let n = 0;
    const { user } = await open({
      "PATCH /api/settings": (init) => (++n === 1 ? first.promise : json(settings(JSON.parse(String(init?.body)) as Partial<Settings>))),
    });
    await user.click(screen.getByRole("checkbox", { name: "On the day" }));
    await user.click(screen.getByRole("checkbox", { name: "1 week before" }));
    expect(count("PATCH /api/settings")).toBe(1);
    expect(bodyOf("PATCH /api/settings")).toEqual({ default_offsets: [7, 1, 0] });
    await act(async () => {
      first.resolve(json(settings({ default_offsets: [7, 1, 0] })));
    });
    await waitFor(() => expect(count("PATCH /api/settings")).toBe(2));
    expect(bodyOf("PATCH /api/settings", 1)).toEqual({ default_offsets: [1, 0] });
    await waitFor(() => expect(screen.getByTestId("settings-status")).toHaveTextContent("Saved."));
    expect(screen.getByRole("checkbox", { name: "1 week before" })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "1 day before" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "On the day" })).toBeChecked();
  });
});

describe("destinations", () => {
  const LIST_ROUTES: Routes = { "GET /api/notify/destinations": () => json({ destinations: [D_OK, D_STALE] }) };
  const WITH_DESTS = settings({ ntfy: false, destinations: 2, stale_destinations: 1 });

  it("lists ntfy and destination rows, marking a stale one", async () => {
    await open(LIST_ROUTES, WITH_DESTS);
    const list = await screen.findByRole("list", { name: "Reminder destinations" });
    expect(await within(list).findByText("Discord: family-server")).toBeInTheDocument();
    expect(within(list).getByText(/stale, not used for reminders/)).toBeInTheDocument();
    expect(within(list).getByRole("button", { name: "Set up phone" })).toBeInTheDocument();
    expect(within(list).getByRole("button", { name: "Check again: old-server" })).toBeInTheDocument();
    expect(within(list).queryByRole("button", { name: /Check again: family-server/ })).not.toBeInTheDocument();
  });

  it("Check again is aria-disabled while in flight, announces and focuses Remove on success", async () => {
    const d = deferred();
    const { user } = await open({
      ...LIST_ROUTES,
      "POST /api/notify/destinations/6/check": () => d.promise,
    }, WITH_DESTS);
    const check = await screen.findByRole("button", { name: "Check again: old-server" });
    await user.click(check);
    expect(check).toHaveAttribute("aria-disabled", "true");
    expect(check).toHaveTextContent("Checking…");
    expect(check).toHaveFocus();
    await user.click(check);
    expect(count("POST /api/notify/destinations/6/check")).toBe(1);
    await act(async () => {
      d.resolve(json({ destination: { ...D_STALE, stale: false }, settings: settings({ ntfy: false, destinations: 2, stale_destinations: 0 }) }));
    });
    await waitFor(() => expect(destStatus()).toHaveTextContent("old-server is deliverable again"));
    expect(screen.getByRole("button", { name: "Remove destination old-server" })).toHaveFocus();
    expect(screen.queryByText(/stale, not used/)).not.toBeInTheDocument();
  });

  it("Check again on a still-stale row announces it and keeps focus on the button", async () => {
    const { user } = await open({
      ...LIST_ROUTES,
      "POST /api/notify/destinations/6/check": () => json({ destination: D_STALE, settings: WITH_DESTS }),
    }, WITH_DESTS);
    const check = await screen.findByRole("button", { name: "Check again: old-server" });
    await user.click(check);
    await waitFor(() => expect(destStatus()).toHaveTextContent("old-server still can't be reached"));
    expect(check).toHaveFocus();
    expect(check).not.toHaveAttribute("aria-disabled");
    expect(screen.getByText(/stale, not used/)).toBeInTheDocument();
  });

  it("Check again announces the notify_unavailable copy on a failure", async () => {
    const { user } = await open({
      ...LIST_ROUTES,
      "POST /api/notify/destinations/6/check": () => json({ error: "notify_unavailable" }, 500),
    }, WITH_DESTS);
    const check = await screen.findByRole("button", { name: "Check again: old-server" });
    await user.click(check);
    await waitFor(() => expect(destStatus()).toHaveTextContent("Reminders are unavailable right now. Try again in a minute."));
    expect(check).toHaveFocus();
    expect(check).not.toHaveAttribute("aria-disabled");
    expect(screen.getByText(/stale, not used/)).toBeInTheDocument();
    expect(count("PATCH /api/settings")).toBe(0);
  });

  it("Remove opens a confirm with Cancel first, then removes, announces and focuses the heading", async () => {
    const { user } = await open({
      ...LIST_ROUTES,
      "DELETE /api/notify/destinations/5": () => json({ settings: settings({ ntfy: false, destinations: 1, stale_destinations: 1 }) }),
    }, WITH_DESTS);
    const remove = await screen.findByRole("button", { name: "Remove destination family-server" });
    await user.click(remove);
    const group = screen.getByRole("group", { name: "Remove destination family-server?" });
    expect(within(group).getByRole("button", { name: "Cancel" })).toHaveFocus();
    expect(group).toHaveTextContent("This app doesn't store the address, so adding it again means pasting it again.");
    expect(group).toHaveTextContent("A webhook gets a new signing secret.");
    expect(count("DELETE /api/notify/destinations/5")).toBe(0);
    await user.keyboard("{Escape}");
    expect(confirms()).toHaveLength(0);
    expect(remove).toHaveFocus();
    await user.click(remove);
    await user.click(within(screen.getByRole("group", { name: "Remove destination family-server?" })).getByRole("button", { name: "Yes, remove" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Where reminders go" })).toHaveFocus());
    expect(destStatus()).toHaveTextContent("Removed family-server");
    expect(screen.queryByText("Discord: family-server")).not.toBeInTheDocument();
  });

  it("a failed Remove announces it, closes the confirm and returns focus to Remove", async () => {
    const { user } = await open({
      ...LIST_ROUTES,
      "DELETE /api/notify/destinations/5": () => json({ error: "internal" }, 500),
    }, WITH_DESTS);
    const remove = await screen.findByRole("button", { name: "Remove destination family-server" });
    await user.click(remove);
    await user.click(within(screen.getByRole("group", { name: "Remove destination family-server?" })).getByRole("button", { name: "Yes, remove" }));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Couldn't remove family-server."));
    expect(confirms()).toHaveLength(0);
    expect(remove).toHaveFocus();
    expect(screen.getByText("Discord: family-server")).toBeInTheDocument();
  });

  it("only one confirm is open at a time and focus follows the new one", async () => {
    const { user } = await open({
      ...LIST_ROUTES,
      "POST /api/notify/ntfy": () => json({ user_id: "u1", setup_url: SETUP_URL, password: null, settings: settings({ destinations: 2, stale_destinations: 1 }) }),
    }, settings({ ntfy: true, destinations: 2, stale_destinations: 1 }));
    await user.click(await screen.findByRole("button", { name: "Remove destination family-server" }));
    await user.click(screen.getByRole("button", { name: "Remove destination old-server" }));
    expect(confirms()).toHaveLength(1);
    const second = screen.getByRole("group", { name: "Remove destination old-server?" });
    expect(within(second).getByRole("button", { name: "Cancel" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    const generate = await screen.findByRole("button", { name: "Generate a new password" });
    await user.click(generate);
    expect(confirms()).toHaveLength(1);
    const reset = screen.getByRole("group", { name: "Generate a new password?" });
    expect(within(reset).getByRole("button", { name: "Cancel" })).toHaveFocus();
    await user.click(screen.getByRole("button", { name: "Remove destination family-server" }));
    expect(confirms()).toHaveLength(1);
    const last = screen.getByRole("group", { name: "Remove destination family-server?" });
    await user.click(within(last).getByRole("button", { name: "Cancel" }));
    expect(confirms()).toHaveLength(0);
    expect(screen.getByRole("button", { name: "Remove destination family-server" })).toHaveFocus();
  });

  it("copy for invalid_url, url_not_public, rate_limited and notify_unavailable on add", async () => {
    let code = "invalid_url";
    const { user } = await open({ "POST /api/notify/destinations": () => json({ error: code }, code === "notify_unavailable" ? 500 : 400) });
    await fillAdd(user, "Family", "https://example.test/hook");
    await waitFor(() => expect(fieldErr("dest-url-err")).toHaveTextContent("That address doesn't look right. Check it and try again."));
    expect(screen.getByLabelText(/webhook URL/i)).toHaveFocus();
    code = "url_not_public";
    await user.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => expect(fieldErr("dest-url-err")).toHaveTextContent("That address isn't reachable from the internet."));
    code = "rate_limited";
    await user.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Too many tries. Wait a minute and try again."));
    code = "notify_unavailable";
    await user.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Reminders are unavailable right now. Try again in a minute."));
  });

  it("asks for a label and a URL before sending", async () => {
    const { user } = await open();
    await user.click(screen.getByRole("button", { name: "Add" }));
    expect(fieldErr("dest-label-err")).toHaveTextContent("Enter a label of up to 50 characters.");
    expect(fieldErr("dest-url-err")).toHaveTextContent("That address doesn't look right. Check it and try again.");
    expect(screen.getByLabelText(/^Label/)).toHaveFocus();
    expect(destStatus()).toHaveTextContent("Enter a label of up to 50 characters.");
    expect(count("POST /api/notify/destinations")).toBe(0);
  });

  it("focuses the URL field when only the URL is missing", async () => {
    const { user } = await open();
    await user.type(screen.getByLabelText(/^Label/), "Family");
    await user.click(screen.getByRole("button", { name: "Add" }));
    expect(screen.getByLabelText(/webhook URL/i)).toHaveFocus();
    expect(destStatus()).toHaveTextContent("That address doesn't look right. Check it and try again.");
  });

  it("keeps a row added before the first destinations load answers, without duplicating it", async () => {
    const initial = deferred();
    const { user } = await open({
      "GET /api/notify/destinations": () => initial.promise,
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "Hooks", HOOK_SECRET),
    });
    await fillAdd(user, "Hooks", "https://example.com/hook");
    await screen.findByText("Webhook: Hooks");
    const created = { id: 9, kind: "webhook", label: "Hooks", hint: "Webhook ending …abc", stale: false };
    await act(async () => {
      initial.resolve(json({ destinations: [D_OK, created] }));
    });
    await screen.findByText("Discord: family-server");
    expect(screen.getAllByText("Webhook: Hooks")).toHaveLength(1);
  });

  it("does not let an earlier destinations load bring back a removed row or drop an added one", async () => {
    const initial = deferred();
    const { user } = await open({
      "GET /api/notify/destinations": () => initial.promise,
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "Hooks", HOOK_SECRET),
    });
    await fillAdd(user, "Hooks", "https://example.com/hook");
    await screen.findByText("Webhook: Hooks");
    await act(async () => {
      initial.resolve(json({ destinations: [D_OK] }));
    });
    await screen.findByText("Discord: family-server");
    expect(screen.getByText("Webhook: Hooks")).toBeInTheDocument();
  });
});

describe("the no-destination warning", () => {
  const NONE = settings({ ntfy: false, destinations: 0, stale_destinations: 0 });
  const warning = () => screen.queryByText("No place to send reminders yet.");

  it("shows when a loaded birthday has reminders on and there is nowhere to send them", async () => {
    await open({}, NONE);
    expect(await screen.findByText("No place to send reminders yet.")).toBeInTheDocument();
    expect(screen.getByText(/Reminders are on for 1 birthday, but you haven't set up a destination/)).toBeInTheDocument();
  });

  it("names the stale destinations when that is the cause", async () => {
    await open({ "GET /api/notify/destinations": () => json({ destinations: [D_STALE] }) }, settings({ ntfy: false, destinations: 1, stale_destinations: 1 }));
    expect(await screen.findByText(/old-server can't be reached/)).toBeInTheDocument();
  });

  it("is hidden when no birthday has reminders on", async () => {
    const { user } = await open({}, NONE, [ADA]);
    await loadListThenSettings(user, "Ada Lovelace");
    expect(warning()).not.toBeInTheDocument();
  });

  it("is hidden when ntfy is set up", async () => {
    const { user } = await open({}, settings({ ntfy: true }));
    await loadListThenSettings(user, "Sam Rivera");
    expect(warning()).not.toBeInTheDocument();
  });

  it("is hidden when a non-stale destination exists", async () => {
    const { user } = await open(
      { "GET /api/notify/destinations": () => json({ destinations: [D_OK, D_STALE] }) },
      settings({ ntfy: false, destinations: 2, stale_destinations: 1 }),
    );
    await loadListThenSettings(user, "Sam Rivera");
    await screen.findByText("Discord: family-server");
    expect(warning()).not.toBeInTheDocument();
  });

  it("clears right after a destination is added, with no reload and no preference change", async () => {
    const pending = deferred();
    const { user } = await open({
      "PATCH /api/settings": () => pending.promise,
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "Hooks", HOOK_SECRET, { ntfy: false, list_view: "upcoming", color_scheme: "confetti" }),
    }, NONE);
    await screen.findByText("No place to send reminders yet.");
    await user.selectOptions(screen.getByLabelText("Birthdays view"), "month");
    await user.click(screen.getByRole("radio", { name: "Frosting" }));
    await fillAdd(user, "Hooks", "https://example.com/hook");
    await waitFor(() => expect(warning()).not.toBeInTheDocument());
    // The notify response carried older preference values: the pending ones stay.
    expect(screen.getByLabelText("Birthdays view")).toHaveValue("month");
    expect(screen.getByRole("radio", { name: "Frosting" })).toBeChecked();
    expect(root().getAttribute("data-palette")).toBe("frosting");
    await act(async () => {
      pending.resolve(json(settings({ list_view: "month", color_scheme: "frosting" })));
    });
  });
});

describe("one-time secrets", () => {
  it("shows a webhook signing secret in a labelled panel that takes focus and is announced", async () => {
    const { user } = await open({ "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET) });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const region = await screen.findByRole("region", { name: "Signing secret for webhook: old-server" });
    expect(within(region).getByText(HOOK_SECRET)).toBeInTheDocument();
    const h2 = within(region).getByRole("heading", { level: 2 });
    await waitFor(() => expect(h2).toHaveFocus());
    expect(screen.getByTestId("secret-notice")).toHaveTextContent("Signing secret for webhook: old-server");
    expect(region).toHaveTextContent("Copy it before you leave this page");
    expect(region).toHaveTextContent("Lost it? Remove this destination and add it again");
    expect(region.textContent).not.toMatch(NO_PROMISE);
    await user.click(within(region).getByRole("button", { name: "Copy" }));
    expect(within(region).getByRole("status")).toHaveTextContent("Copied");
    expect(await navigator.clipboard.readText()).toBe(HOOK_SECRET);
  });

  it("says so when copying fails", async () => {
    const { user } = await open({ "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET) });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const region = await screen.findByRole("region", { name: HOOK_REGION("old-server") });
    vi.spyOn(navigator.clipboard, "writeText").mockRejectedValue(new Error("denied"));
    await user.click(within(region).getByRole("button", { name: "Copy" }));
    await waitFor(() => expect(within(region).getByRole("status")).toHaveTextContent("Couldn't copy"));
  });

  it("keeps the secret when the person leaves Settings while the add is still in flight", async () => {
    const pending = deferred();
    const { user } = await open({ "POST /api/notify/destinations": () => pending.promise });
    await fillAdd(user, "old-server", "https://example.com/hook");
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    expect(screen.queryByLabelText("Birthdays view")).not.toBeInTheDocument();
    await act(async () => {
      pending.resolve(WEBHOOK_CREATED(9, "old-server", HOOK_SECRET)());
    });
    const region = await screen.findByRole("region", { name: HOOK_REGION("old-server") });
    expect(region).toHaveTextContent(HOOK_SECRET);
  });

  it("stacks a second webhook secret, and acknowledging one leaves the other", async () => {
    let n = 0;
    const { user } = await open({
      "POST /api/notify/destinations": () => WEBHOOK_CREATED(++n + 8, n === 1 ? "first" : "second", n === 1 ? HOOK_SECRET : HOOK_SECRET_2)(),
    });
    await fillAdd(user, "first", "https://example.com/a");
    await screen.findByRole("region", { name: "Signing secret for webhook: first" });
    await fillAdd(user, "second", "https://example.com/b");
    const second = await screen.findByRole("region", { name: "Signing secret for webhook: second" });
    const first = screen.getByRole("region", { name: "Signing secret for webhook: first" });
    expect(first).toHaveTextContent(HOOK_SECRET);
    await waitFor(() => expect(within(second).getByRole("heading", { level: 2 })).toHaveFocus());
    await waitFor(() => expect(screen.getByTestId("secret-notice")).toHaveTextContent("Signing secret for webhook: second"));
    expect(screen.getByTestId("secret-notice")).not.toHaveTextContent("webhook: first");
    const regions = screen.getAllByRole("region");
    expect(regions.indexOf(first)).toBeLessThan(regions.indexOf(second));
    await user.click(within(first).getByRole("button", { name: "I've saved it" }));
    expect(screen.queryByRole("region", { name: "Signing secret for webhook: first" })).not.toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Signing secret for webhook: second" })).toHaveTextContent(HOOK_SECRET_2);
  });

  it("acknowledging returns focus to the still-mounted trigger", async () => {
    const { user } = await open({ "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET) });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const region = await screen.findByRole("region", { name: "Signing secret for webhook: old-server" });
    await user.click(within(region).getByRole("button", { name: "I've saved it" }));
    expect(screen.getByRole("button", { name: "Add" })).toHaveFocus();
  });

  it("acknowledging falls back to the screen heading when the trigger is gone, never another panel", async () => {
    const { user } = await open({ "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET) });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const region = await screen.findByRole("region", { name: "Signing secret for webhook: old-server" });
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    await user.click(within(region).getByRole("button", { name: "I've saved it" }));
    expect(await screen.findByRole("heading", { level: 2, name: /Add/ })).toHaveFocus();
  });

  it("acknowledging never focuses another panel's heading", async () => {
    let n = 0;
    const { user } = await open({
      "POST /api/notify/destinations": () => WEBHOOK_CREATED(++n + 8, n === 1 ? "first" : "second", n === 1 ? HOOK_SECRET : HOOK_SECRET_2)(),
    });
    await fillAdd(user, "first", "https://example.com/a");
    const first = await screen.findByRole("region", { name: HOOK_REGION("first") });
    await fillAdd(user, "second", "https://example.com/b");
    const second = await screen.findByRole("region", { name: HOOK_REGION("second") });
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    await user.click(within(second).getByRole("button", { name: "I've saved it" }));
    const screenH = await screen.findByRole("heading", { level: 2, name: /Add/ });
    expect(screenH).toHaveFocus();
    expect(within(first).getByRole("heading", { level: 2 })).not.toHaveFocus();
  });

  it("the panel is on every tab and survives a tab press, a hash change and the expired-session state", async () => {
    const { user } = await open({
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET),
      "PATCH /api/settings": () => html(200),
    });
    await fillAdd(user, "old-server", "https://example.com/hook");
    await screen.findByRole("region", { name: "Signing secret for webhook: old-server" });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    expect(screen.getByRole("region", { name: "Signing secret for webhook: old-server" })).toBeInTheDocument();
    await user.click(within(nav()).getByRole("link", { name: /Add/ }));
    expect(screen.getByRole("region", { name: "Signing secret for webhook: old-server" })).toBeInTheDocument();
    act(() => {
      window.history.pushState(null, "", "#/settings");
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    });
    await user.selectOptions(await screen.findByLabelText("Birthdays view"), "month");
    expect(await screen.findByText("Your sign-in has expired.")).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Signing secret for webhook: old-server" })).toHaveTextContent(HOOK_SECRET);
  });

  it("registers a beforeunload guard while a secret is held and removes it after the last acknowledgement", async () => {
    let n = 0;
    const { user } = await open({
      "POST /api/notify/destinations": () => WEBHOOK_CREATED(++n + 8, n === 1 ? "first" : "second", n === 1 ? HOOK_SECRET : HOOK_SECRET_2)(),
    });
    const fire = () => {
      const e = new Event("beforeunload", { cancelable: true });
      window.dispatchEvent(e);
      return e.defaultPrevented;
    };
    expect(fire()).toBe(false);
    await fillAdd(user, "first", "https://example.com/a");
    const first = await screen.findByRole("region", { name: "Signing secret for webhook: first" });
    await fillAdd(user, "second", "https://example.com/b");
    const second = await screen.findByRole("region", { name: "Signing secret for webhook: second" });
    expect(fire()).toBe(true);
    await user.click(within(first).getByRole("button", { name: "I've saved it" }));
    expect(fire()).toBe(true);
    await user.click(within(second).getByRole("button", { name: "I've saved it" }));
    expect(fire()).toBe(false);
  });

  it("shows the ntfy password once, then the lost-password state on a repeat call", async () => {
    let n = 0;
    const { user } = await open({
      "POST /api/notify/ntfy": () =>
        json({ user_id: "u1", setup_url: SETUP_URL, password: ++n === 1 ? NTFY_PASSWORD : null, settings: settings({ ntfy: true }) }),
    }, settings({ ntfy: false }));
    await user.click(screen.getByRole("button", { name: "Set up phone" }));
    const region = await screen.findByRole("region", { name: "Your phone notification password" });
    expect(region).toHaveTextContent(NTFY_PASSWORD);
    expect(region).toHaveTextContent("Lost it? Generate a new password");
    expect(within(region).getByRole("link", { name: "Open the setup page" })).toHaveAttribute("href", SETUP_URL);
    await waitFor(() => expect(within(region).getByRole("heading", { level: 2 })).toHaveFocus());
    expect(screen.queryByRole("heading", { name: "Phone notifications are set up" })).not.toBeInTheDocument();
    expect(region.textContent).not.toMatch(NO_PROMISE);
    await user.click(within(region).getByRole("button", { name: "I've saved it" }));
    expect(screen.getByRole("button", { name: "Show setup again" })).toHaveFocus();
    // No password:null answer has happened yet, so acknowledging alone does not show the lost-password state.
    expect(screen.queryByRole("heading", { name: "Phone notifications are set up" })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    expect(await screen.findByRole("heading", { name: "Phone notifications are set up" })).toBeInTheDocument();
    expect(screen.queryByText(NTFY_PASSWORD)).not.toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Your phone notification password" })).not.toBeInTheDocument();
    expect(screen.getByText(/If you lost it, generate a new one/)).toBeInTheDocument();
  });

  it("a password:null repeat call never replaces an entry that is still held", async () => {
    let n = 0;
    const { user } = await open({
      "POST /api/notify/ntfy": () =>
        json({ user_id: "u1", setup_url: SETUP_URL, password: ++n === 1 ? NTFY_PASSWORD : null, settings: settings({ ntfy: true }) }),
    }, settings({ ntfy: false }));
    await user.click(screen.getByRole("button", { name: "Set up phone" }));
    await screen.findByRole("region", { name: "Your phone notification password" });
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    await waitFor(() => expect(count("POST /api/notify/ntfy")).toBe(2));
    expect(document.querySelectorAll("section[data-secret]")).toHaveLength(1);
    expect(screen.getByTestId("secret-1-value")).toHaveTextContent(NTFY_PASSWORD);
    expect(screen.queryByRole("heading", { name: "Phone notifications are set up" })).not.toBeInTheDocument();
  });

  it("Generate a new password asks for confirm first, then shows the new password beside the webhook secret", async () => {
    const { user } = await open({
      "POST /api/notify/ntfy": () => json({ user_id: "u1", setup_url: SETUP_URL, password: null, settings: settings({ ntfy: true, destinations: 1 }) }),
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET),
      "POST /api/notify/ntfy/reset": () => json({ password: NTFY_PASSWORD, setup_url: SETUP_URL, settings: settings({ ntfy: true, destinations: 1 }) }),
    });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const hook = await screen.findByRole("region", { name: "Signing secret for webhook: old-server" });
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    const generate = await screen.findByRole("button", { name: "Generate a new password" });
    await user.click(generate);
    expect(count("POST /api/notify/ntfy/reset")).toBe(0);
    await user.click(within(screen.getByRole("group", { name: "Generate a new password?" })).getByRole("button", { name: "Yes, generate" }));
    const ntfy = await screen.findByRole("region", { name: "Your phone notification password" });
    expect(ntfy).toHaveTextContent(NTFY_PASSWORD);
    expect(hook).toHaveTextContent(HOOK_SECRET);
    await waitFor(() => expect(within(ntfy).getByRole("heading", { level: 2 })).toHaveFocus());
    expect(secretSections()).toHaveLength(2);
    // The Generate button is gone with the lost-password panel, so acknowledging falls back to the screen heading.
    await user.click(within(ntfy).getByRole("button", { name: "I've saved it" }));
    expect(screen.getByRole("heading", { level: 2, name: "Settings" })).toHaveFocus();
    expect(screen.getByRole("region", { name: HOOK_REGION("old-server") })).toHaveTextContent(HOOK_SECRET);
  });

  it("a new ntfy password replaces only the ntfy entry and leaves the webhook entry as it was", async () => {
    const NEW_PASSWORD = "n3w0-pass-wrd9-zz11";
    let n = 0;
    const { user } = await open({
      "POST /api/notify/ntfy": () =>
        json({ user_id: "u1", setup_url: SETUP_URL, password: ++n === 1 ? NTFY_PASSWORD : NEW_PASSWORD, settings: settings({ ntfy: true }) }),
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET),
    }, settings({ ntfy: false }));
    await user.click(screen.getByRole("button", { name: "Set up phone" }));
    await screen.findByRole("region", { name: NTFY_REGION });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const hook = await screen.findByRole("region", { name: HOOK_REGION("old-server") });
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    await waitFor(() => expect(screen.getByRole("region", { name: NTFY_REGION })).toHaveTextContent(NEW_PASSWORD));
    expect(secretSections()).toHaveLength(2);
    expect(screen.queryByText(NTFY_PASSWORD)).not.toBeInTheDocument();
    expect(screen.getByRole("region", { name: HOOK_REGION("old-server") })).toBe(hook);
    expect(hook).toHaveTextContent(HOOK_SECRET);
    await waitFor(() => expect(within(screen.getByRole("region", { name: NTFY_REGION })).getByRole("heading", { level: 2 })).toHaveFocus());
  });

  it("shows the lost-password state when the first set-up answers password:null", async () => {
    const { user } = await open({
      "POST /api/notify/ntfy": () => json({ user_id: "u1", setup_url: SETUP_URL, password: null, settings: settings({ ntfy: true }) }),
    }, settings({ ntfy: false }));
    await user.click(screen.getByRole("button", { name: "Set up phone" }));
    expect(await screen.findByRole("heading", { name: "Phone notifications are set up" })).toBeInTheDocument();
    expect(screen.getByText(/If you lost it, generate a new one/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Generate a new password" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Open the setup page" })).toHaveAttribute("href", SETUP_URL);
    expect(secretSections()).toHaveLength(0);
  });

  it("copy for ntfy_not_set_up and rate_limited on reset", async () => {
    let code = "ntfy_not_set_up";
    const { user } = await open({
      "POST /api/notify/ntfy": () => json({ user_id: "u1", setup_url: SETUP_URL, password: null, settings: settings({ ntfy: true }) }),
      "POST /api/notify/ntfy/reset": () => json({ error: code }, code === "rate_limited" ? 429 : 409),
    });
    await user.click(screen.getByRole("button", { name: "Show setup again" }));
    for (const [c, text] of [
      ["ntfy_not_set_up", "Phone notifications aren't set up yet."],
      ["rate_limited", "Too many tries. Wait a minute and try again."],
    ] as const) {
      code = c;
      await user.click(await screen.findByRole("button", { name: "Generate a new password" }));
      await user.click(within(screen.getByRole("group", { name: "Generate a new password?" })).getByRole("button", { name: "Yes, generate" }));
      await waitFor(() => expect(destStatus()).toHaveTextContent(text));
    }
  });

  it("never writes either secret to localStorage or sessionStorage", async () => {
    const setItem = vi.spyOn(Storage.prototype, "setItem");
    const { user } = await open({
      "PATCH /api/settings": (init) => json(settings({ ntfy: false, ...(JSON.parse(String(init?.body)) as Partial<Settings>) })),
      "POST /api/notify/ntfy": () => json({ user_id: "u1", setup_url: SETUP_URL, password: NTFY_PASSWORD, settings: settings({ ntfy: true }) }),
      "POST /api/notify/destinations": WEBHOOK_CREATED(9, "old-server", HOOK_SECRET),
    }, settings({ ntfy: false }));
    // Picking a scheme writes the palette to localStorage, so the stores really are in use during this flow.
    await user.click(screen.getByRole("radio", { name: "Frosting" }));
    await user.click(screen.getByRole("button", { name: "Set up phone" }));
    await screen.findByRole("region", { name: NTFY_REGION });
    await fillAdd(user, "old-server", "https://example.com/hook");
    const hook = await screen.findByRole("region", { name: HOOK_REGION("old-server") });
    const noSecrets = () => {
      expect(window.localStorage.length).toBeGreaterThan(0);
      for (const store of [window.localStorage, window.sessionStorage]) {
        for (let i = 0; i < store.length; i++) {
          const k = store.key(i) ?? "";
          const entry = `${k}=${store.getItem(k) ?? ""}`;
          expect(entry).not.toContain(NTFY_PASSWORD);
          expect(entry).not.toContain(HOOK_SECRET);
        }
      }
      expect(setItem).toHaveBeenCalled();
      for (const [k, v] of setItem.mock.calls) {
        expect(`${k}=${v}`).not.toContain(NTFY_PASSWORD);
        expect(`${k}=${v}`).not.toContain(HOOK_SECRET);
      }
    };
    noSecrets();
    await user.click(within(hook).getByRole("button", { name: "I've saved it" }));
    await user.click(within(screen.getByRole("region", { name: NTFY_REGION })).getByRole("button", { name: "I've saved it" }));
    noSecrets();
  });
});
