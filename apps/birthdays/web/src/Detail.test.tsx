import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { Birthday, Gift, Settings } from "./api";

type Handler = (init?: RequestInit) => Response | Promise<Response>;
type Routes = Record<string, Handler>;

const JSON_CT = { "Content-Type": "application/json" };
const EMAIL = "alex@example.com";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_CT });
}
function html(status: number): Response {
  return new Response("<html>edge</html>", { status, headers: { "Content-Type": "text/html" } });
}
function noContent(): Response {
  return new Response(null, { status: 204 });
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

function bd(id: number, name: string, month: number, day: number, over: Partial<Birthday> = {}): Birthday {
  return { id, name, month, day, year: null, is_mine: true, owner_email: EMAIL, reminder_offsets: [], ...over };
}

const SAM = bd(1, "Sam Rivera", 11, 16, { year: 1990, reminder_offsets: [7, 1] });
const ADA = bd(2, "Ada Lovelace", 11, 17);
const ZED = bd(3, "Zed Young", 11, 20, { is_mine: false, owner_email: "pat@example.com" });
const LIST = [SAM, ADA, ZED];

const G_SHARED: Gift = { id: 11, text: "Ceramics class voucher", shared: true, author_email: EMAIL, mine: true };
const G_PRIVATE: Gift = { id: 12, text: "Hiking socks", shared: false, author_email: EMAIL, mine: true };
const G_OTHER: Gift = { id: 13, text: "Board game: Wingspan", shared: true, author_email: "partner@example.com", mine: false };

const OWNER_DETAIL: Routes = {
  "GET /api/birthdays/1": () =>
    json({ birthday: SAM, shares: ["pat@example.com", "lee@example.com"], gifts: [G_SHARED, G_PRIVATE, G_OTHER] }),
};
const RECIPIENT_DETAIL: Routes = {
  "GET /api/birthdays/3": () => json({ birthday: ZED, gifts: [] }),
};

let calls: { key: string; body: unknown }[] = [];

function mount(routes: Routes = {}, settings: Settings = SETTINGS) {
  calls = [];
  const table: Routes = {
    "GET /api/me": () => json({ email: EMAIL, settings }),
    "GET /api/birthdays": () => json({ birthdays: LIST }),
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
function go(hash: string, state: unknown = null) {
  window.history.replaceState(state, "", hash);
}

const live = () => screen.getByTestId("detail-live");
const nav = () => screen.getByRole("navigation", { name: "Main" });
const trigger = (name: string) => screen.findByRole("button", { name });
// Open confirm prompts only (a fieldset is a group too).
const confirms = () => screen.queryAllByRole("group").filter((el) => el.classList.contains("confirm"));

// The edit form's fields stay disabled until GET /api/me has answered; wait for that before typing.
async function nameField() {
  const input = await screen.findByLabelText("Name");
  await waitFor(() => expect(input).toBeEnabled());
  return input;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2026, 10, 16, 12, 0, 0));
  window.sessionStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  window.sessionStorage.clear();
});

describe("owner and recipient controls", () => {
  it("shows the owner every control", async () => {
    go("#/b/1");
    mount(OWNER_DETAIL);
    await screen.findByRole("heading", { level: 2, name: "Sam Rivera" });
    expect(await screen.findByRole("form", { name: "Edit birthday" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "My reminders" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "My gift ideas" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Gift ideas shared by others" })).toBeInTheDocument();
    expect(screen.getByRole("list", { name: "People this birthday is shared with" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument();
    expect(screen.getByRole("checkbox", { name: "1 week before" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "1 day before" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "On the day" })).not.toBeChecked();
    expect(screen.getByText(/Untick all of them to turn reminders off/)).toBeInTheDocument();
    expect(screen.getByText(/from partner@example.com/)).toBeInTheDocument();
  });

  it("shows a recipient read-only content and no edit, delete or sharing controls", async () => {
    go("#/b/3");
    mount(RECIPIENT_DETAIL);
    await screen.findByRole("heading", { level: 2, name: "Zed Young" });
    expect(await screen.findByText("Shared with you by pat@example.com. Only they can edit it.")).toBeInTheDocument();
    expect(screen.queryByRole("form", { name: "Edit birthday" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Save" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Shared with" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/^Share with/)).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "My reminders" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "My gift ideas" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Remove from my list" })).toBeInTheDocument();
    // Empty sections: no gift ideas by anyone, so "shared by others" is hidden for a recipient too.
    expect(screen.getByText("No gift ideas yet.")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Gift ideas shared by others" })).not.toBeInTheDocument();
  });

  it("says Not shared with anyone and hides ideas shared by others when there are none", async () => {
    go("#/b/2");
    mount({ "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }) });
    expect(await screen.findByText("Not shared with anyone.")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Gift ideas shared by others" })).not.toBeInTheDocument();
  });

  it("a recipient's Remove from my list needs a confirm that opens on Cancel", async () => {
    go("#/b/3");
    const { user } = mount({ ...RECIPIENT_DETAIL, "DELETE /api/birthdays/3": noContent });
    await user.click(await trigger("Remove from my list"));
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
    expect(count("DELETE /api/birthdays/3")).toBe(0);
    await user.click(screen.getByRole("button", { name: "Yes, remove" }));
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
    expect(screen.getByTestId("app-notice")).toHaveTextContent("Removed Zed Young from your list.");
    await waitFor(() => expect(screen.queryByRole("link", { name: "Zed Young" })).not.toBeInTheDocument());
  });
});

describe("gift ideas", () => {
  it("toggles an idea's Share checkbox with a PATCH and announces it", async () => {
    go("#/b/1");
    const { user } = mount({
      ...OWNER_DETAIL,
      "PATCH /api/gifts/12": () => json({ ...G_PRIVATE, shared: true }),
    });
    const box = await screen.findByRole("checkbox", { name: "Share gift idea: Hiking socks" });
    expect(box).not.toBeChecked();
    await user.click(box);
    await waitFor(() => expect(box).toBeChecked());
    expect(bodyOf("PATCH /api/gifts/12")).toEqual({ shared: true });
    expect(live()).toHaveTextContent("Gift idea shared.");
  });

  it("Remove is immediate (no confirm) and focus moves to the next idea's Remove, else the input", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/gifts/11": noContent, "DELETE /api/gifts/12": noContent });
    await user.click(await trigger("Remove gift idea: Ceramics class voucher"));
    expect(confirms()).toHaveLength(0);
    await waitFor(() => expect(screen.getByRole("button", { name: "Remove gift idea: Hiking socks" })).toHaveFocus());
    expect(screen.queryByText("Ceramics class voucher")).not.toBeInTheDocument();
    expect(live()).toHaveTextContent("Removed gift idea.");
    await user.click(screen.getByRole("button", { name: "Remove gift idea: Hiking socks" }));
    await waitFor(() => expect(screen.getByLabelText("New gift idea")).toHaveFocus());
    expect(screen.getByText("No gift ideas yet.")).toBeInTheDocument();
  });

  it("Add idea keeps focus in the cleared input and announces the addition", async () => {
    go("#/b/1");
    const created: Gift = { id: 14, text: "Scarf", shared: false, author_email: EMAIL, mine: true };
    const { user } = mount({ ...OWNER_DETAIL, "POST /api/birthdays/1/gifts": () => json(created, 201) });
    const input = await screen.findByLabelText("New gift idea");
    await waitFor(() => expect(input).toBeEnabled());
    await user.type(input, "Scarf");
    await user.click(screen.getByRole("button", { name: "Add idea" }));
    expect(await screen.findByText("Scarf")).toBeInTheDocument();
    expect(bodyOf("POST /api/birthdays/1/gifts")).toEqual({ text: "Scarf" });
    expect(input).toHaveValue("");
    expect(input).toHaveFocus();
    expect(live()).toHaveTextContent("Added gift idea.");
  });

  it("an empty idea and the 50-idea limit show a field error", async () => {
    go("#/b/1");
    const { user } = mount({
      ...OWNER_DETAIL,
      "POST /api/birthdays/1/gifts": () => json({ error: "too_many_gifts" }, 400),
    });
    const input = await screen.findByLabelText("New gift idea");
    await waitFor(() => expect(input).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Add idea" }));
    expect(input).toHaveAttribute("aria-invalid", "true");
    expect(input).toHaveAccessibleDescription("Write something first (up to 200 characters).");
    expect(count("POST /api/birthdays/1/gifts")).toBe(0);
    await user.type(input, "One more");
    await user.click(screen.getByRole("button", { name: "Add idea" }));
    await waitFor(() => expect(input).toHaveAccessibleDescription(/limit of 50 gift ideas/));
  });
});

describe("sharing and confirms", () => {
  it("Stop sharing shows the hint, confirms first, then focuses the Shared with heading and announces", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/birthdays/1/shares": noContent });
    const stop = await trigger("Stop sharing with pat@example.com");
    expect(screen.getAllByText("Stopping removes their reminders and gift ideas for this birthday.")).toHaveLength(1);
    await user.click(stop);
    const group = screen.getByRole("group", { name: "Stop sharing with pat@example.com?" });
    expect(within(group).getByRole("button", { name: "Cancel" })).toHaveFocus();
    expect(count("DELETE /api/birthdays/1/shares")).toBe(0);
    expect(live()).toHaveTextContent("Stop sharing with pat@example.com? Confirm or cancel.");
    await user.click(within(group).getByRole("button", { name: "Yes, stop sharing" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Shared with" })).toHaveFocus());
    expect(bodyOf("DELETE /api/birthdays/1/shares")).toEqual({ email: "pat@example.com" });
    expect(confirms()).toHaveLength(0);
    const list = screen.getByRole("list", { name: "People this birthday is shared with" });
    expect(within(list).queryByText("pat@example.com")).not.toBeInTheDocument();
    expect(within(list).getByText("lee@example.com")).toBeInTheDocument();
    expect(live()).toHaveTextContent("Stopped sharing with pat@example.com.");
  });

  it("Enter on the prompt cancels and Cancel returns focus to the button that opened it", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/birthdays/1/shares": noContent });
    const stop = await trigger("Stop sharing with lee@example.com");
    await user.click(stop);
    await user.keyboard("{Enter}");
    expect(confirms()).toHaveLength(0);
    expect(stop).toHaveFocus();
    expect(count("DELETE /api/birthdays/1/shares")).toBe(0);
    await user.click(stop);
    await user.keyboard("{Escape}");
    expect(confirms()).toHaveLength(0);
    expect(stop).toHaveFocus();
  });

  it("only one confirm is open at a time and focus follows the new one", async () => {
    go("#/b/1");
    const { user } = mount(OWNER_DETAIL);
    await user.click(await trigger("Stop sharing with pat@example.com"));
    await user.click(screen.getByRole("button", { name: "Delete" }));
    const groups = confirms();
    expect(groups).toHaveLength(1);
    expect(groups[0]).toHaveAccessibleName("Delete Sam Rivera for everyone?");
    expect(within(groups[0] as HTMLElement).getByRole("button", { name: "Cancel" })).toHaveFocus();
    const second = screen.getByRole("button", { name: "Stop sharing with lee@example.com" });
    await user.click(second);
    expect(confirms()).toHaveLength(1);
    const last = screen.getByRole("group", { name: "Stop sharing with lee@example.com?" });
    expect(within(last).getByRole("button", { name: "Cancel" })).toHaveFocus();
    await user.click(within(last).getByRole("button", { name: "Cancel" }));
    expect(confirms()).toHaveLength(0);
    expect(second).toHaveFocus();
    // Settings (Step 11) has its own single-confirm state (Remove destination, Generate a new password); Detail and
    // Settings are never mounted together, so Settings.test.tsx carries that test.
  });

  it("re-opening the same confirm moves focus back to its Cancel", async () => {
    go("#/b/1");
    const { user } = mount(OWNER_DETAIL);
    const del = await trigger("Delete");
    await user.click(del);
    await user.click(del);
    expect(confirms()).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
  });

  it("the owner's Delete confirm opens on Cancel, announces, and Cancel returns focus to Delete", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/birthdays/1": noContent });
    const del = await trigger("Delete");
    await user.click(del);
    expect(screen.getByRole("button", { name: "Yes, delete" })).not.toHaveFocus();
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
    expect(live()).toHaveTextContent("Delete Sam Rivera for everyone? Confirm or cancel.");
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(confirms()).toHaveLength(0);
    expect(del).toHaveFocus();
    expect(count("DELETE /api/birthdays/1")).toBe(0);
  });

  it("a share action that finds the birthday gone shows the not-found panel", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/birthdays/1/shares": () => json({ error: "not_found" }, 404) });
    await user.click(await trigger("Stop sharing with pat@example.com"));
    await user.click(screen.getByRole("button", { name: "Yes, stop sharing" }));
    await screen.findByRole("heading", { level: 2, name: "Birthday not found" });
    expect(confirms()).toHaveLength(0);
  });

  it("shares with an email, and shows the self-share copy as a field error", async () => {
    go("#/b/2");
    const { user } = mount({
      "GET /api/birthdays/2": () => json({ birthday: ADA, shares: [], gifts: [] }),
      "POST /api/birthdays/2/shares": (init) => {
        const email = (JSON.parse(String(init?.body)) as { email: string }).email;
        return email === EMAIL ? json({ error: "self_share" }, 400) : json({ email }, 201);
      },
    });
    const input = await screen.findByLabelText(/^Share with/);
    await waitFor(() => expect(input).toBeEnabled());
    await user.type(input, EMAIL);
    await user.click(screen.getByRole("button", { name: "Share" }));
    await waitFor(() => expect(input).toHaveAttribute("aria-invalid", "true"));
    expect(input).toHaveAccessibleDescription("You already have this birthday.");
    expect(input).toHaveFocus();
    await user.clear(input);
    await user.type(input, "sam@example.com");
    await user.click(screen.getByRole("button", { name: "Share" }));
    expect(await screen.findByRole("button", { name: "Stop sharing with sam@example.com" })).toBeInTheDocument();
    expect(input).toHaveValue("");
    expect(live()).toHaveTextContent("Shared with sam@example.com.");
  });
});

describe("owner edit form", () => {
  it("validates with the Add copy, focuses the first invalid field, then saves and updates the header", async () => {
    go("#/b/1");
    const SAVED = { ...SAM, name: "Sammy R", month: 4, day: 30 };
    let saved = false;
    const { user } = mount({
      "GET /api/birthdays/1": () => json({ birthday: saved ? SAVED : SAM, shares: [], gifts: [] }),
      "PUT /api/birthdays/1": () => {
        saved = true;
        return json(SAVED);
      },
    });
    const name = await nameField();
    await user.clear(name);
    await user.selectOptions(screen.getByLabelText("Month"), "April");
    const day = screen.getByLabelText("Day");
    await user.clear(day);
    await user.type(day, "31");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(name).toHaveFocus();
    expect(name).toHaveAttribute("aria-invalid", "true");
    expect(name).toHaveAccessibleDescription("Enter a name.");
    await user.type(name, "Sammy R");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(day).toHaveFocus();
    expect(day).toHaveAccessibleDescription("April has 30 days.");
    expect(count("PUT /api/birthdays/1")).toBe(0);
    await user.clear(day);
    await user.type(day, "30");
    await user.click(screen.getByRole("button", { name: "Save" }));
    await screen.findByRole("heading", { level: 2, name: "Sammy R" });
    expect(bodyOf("PUT /api/birthdays/1")).toEqual({ name: "Sammy R", month: 4, day: 30, year: 1990 });
    expect(screen.getByTestId("edit-status")).toHaveTextContent("Saved.");
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toBeNull();
    // Leave and return: the app-level draft is gone too, and the field shows the new server values.
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await user.click(await screen.findByRole("link", { name: /Sammy R/ }));
    expect(await nameField()).toHaveValue("Sammy R");
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
  });

  it("shows the 2023 no-leap-day copy on the day field", async () => {
    go("#/b/1");
    const { user } = mount(OWNER_DETAIL);
    await nameField();
    await user.selectOptions(screen.getByLabelText("Month"), "February");
    const day = screen.getByLabelText("Day");
    await user.clear(day);
    await user.type(day, "29");
    const year = screen.getByLabelText(/^Year/);
    await user.clear(year);
    await user.type(year, "2023");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(day).toHaveAccessibleDescription("2023 had no February 29.");
    expect(day).toHaveFocus();
    expect(count("PUT /api/birthdays/1")).toBe(0);
  });

  it.each([
    ["invalid_name", "Name", "Enter a name of up to 100 characters."],
    ["invalid_date", "Day", "That date doesn't exist. Check the month and day."],
    ["invalid_year", "Year", "Enter a year from 1900 to 2200, or leave it empty."],
  ])("maps the server's %s to its field with focus and keeps the draft", async (code, label, copy) => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "PUT /api/birthdays/1": () => json({ error: code }, 400) });
    const name = await nameField();
    await user.type(name, "y");
    await user.click(screen.getByRole("button", { name: "Save" }));
    const field = await screen.findByLabelText(new RegExp(`^${label}`));
    await waitFor(() => expect(field).toHaveAccessibleDescription(copy));
    expect(field).toHaveAttribute("aria-invalid", "true");
    expect(field).toHaveFocus();
    expect(name).toHaveValue("Sam Riveray");
  });

  it("keeps text typed while a save is in flight", async () => {
    go("#/b/1");
    const gate = deferred();
    const { user } = mount({ ...OWNER_DETAIL, "PUT /api/birthdays/1": () => gate.promise });
    const name = await nameField();
    await user.type(name, "a");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(screen.getByTestId("edit-status")).toHaveTextContent("Saving…");
    await user.type(name, "b");
    gate.resolve(json({ ...SAM, name: "Sam Riveraa" }));
    await screen.findByRole("heading", { level: 2, name: "Sam Riveraa" });
    expect(name).toHaveValue("Sam Rivera" + "ab");
  });

  it("an edit back to the server values, then a new edit, is not shown as restored", async () => {
    window.sessionStorage.setItem(
      "birthdays:edit-draft:1",
      JSON.stringify({ name: "Sam Riverax", month: 11, day: "16", year: "1990", email: EMAIL }),
    );
    go("#/b/1");
    const { user } = mount(OWNER_DETAIL);
    const note = await screen.findByText("Unsaved changes restored.");
    expect(note.closest('[role="status"]')).not.toBeNull();
    const name = await nameField();
    await user.type(name, "z");
    expect(screen.queryByText("Unsaved changes restored.")).not.toBeInTheDocument();
    await user.clear(name);
    await user.type(name, "Sam Rivera");
    await user.type(name, "q");
    expect(screen.queryByText("Unsaved changes restored.")).not.toBeInTheDocument();
  });

  it("keeps a dirty edit when leaving and returning, marks it restored, and Discard resets it", async () => {
    go("#/b/1");
    const { user } = mount(OWNER_DETAIL);
    const name = await nameField();
    await user.clear(name);
    await user.type(name, "Sammy");
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toContain("Sammy");
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await user.click(await screen.findByRole("link", { name: "Sam turns 36" }));
    const again = await nameField();
    expect(again).toHaveValue("Sammy");
    expect(screen.getByText("Unsaved changes restored.").closest('[role="status"]')).not.toBeNull();
    // The header still shows the server values.
    expect(screen.getByRole("heading", { level: 2, name: "Sam Rivera" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Discard" }));
    expect(again).toHaveValue("Sam Rivera");
    expect(again).toHaveFocus();
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toBeNull();
    expect(screen.getByTestId("edit-status")).toHaveTextContent("Unsaved changes discarded.");
    // Leave and return: neither store brings the draft back.
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    await screen.findByRole("heading", { level: 2, name: "Birthdays" });
    await user.click(await screen.findByRole("link", { name: "Sam turns 36" }));
    expect(await nameField()).toHaveValue("Sam Rivera");
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
  });

  it("restores a draft from sessionStorage after a reload only for the same email", async () => {
    window.sessionStorage.setItem(
      "birthdays:edit-draft:1",
      JSON.stringify({ name: "Sammy", month: 11, day: "16", year: "1990", email: EMAIL }),
    );
    go("#/b/1");
    mount(OWNER_DETAIL);
    expect(await screen.findByDisplayValue("Sammy")).toBeInTheDocument();
    expect(await screen.findByText("Unsaved changes restored.")).toBeInTheDocument();
  });

  it("discards another person's stored draft", async () => {
    window.sessionStorage.setItem(
      "birthdays:edit-draft:1",
      JSON.stringify({ name: "Sammy", month: 11, day: "16", year: "1990", email: "someone@else.test" }),
    );
    go("#/b/1");
    mount(OWNER_DETAIL);
    expect(await screen.findByDisplayValue("Sam Rivera")).toBeInTheDocument();
    await waitFor(() => expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toBeNull());
    expect(screen.queryByText(/Unsaved changes restored/)).not.toBeInTheDocument();
  });

  it("clears the draft when the birthday is deleted", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "DELETE /api/birthdays/1": noContent });
    const name = await nameField();
    await user.type(name, "x");
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).not.toBeNull();
    await user.click(await trigger("Delete"));
    await user.click(screen.getByRole("button", { name: "Yes, delete" }));
    await waitFor(() => expect(window.location.hash).toBe("#/birthdays"));
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toBeNull();
  });
});

describe("My reminders", () => {
  it("serializes rapid toggles: one PUT at a time, the latest desired value sent next", async () => {
    go("#/b/1");
    const first = deferred();
    let n = 0;
    const { user } = mount({
      ...OWNER_DETAIL,
      "PUT /api/birthdays/1/reminders": () => (++n === 1 ? first.promise : json({ offsets: [1, 0] })),
    });
    const week = await screen.findByRole("checkbox", { name: "1 week before" });
    await waitFor(() => expect(week).toBeEnabled());
    await user.click(week);
    await user.click(screen.getByRole("checkbox", { name: "On the day" }));
    expect(count("PUT /api/birthdays/1/reminders")).toBe(1);
    expect(bodyOf("PUT /api/birthdays/1/reminders", 0)).toEqual({ offsets: [1] });
    first.resolve(json({ offsets: [1] }));
    await waitFor(() => expect(count("PUT /api/birthdays/1/reminders")).toBe(2));
    expect(bodyOf("PUT /api/birthdays/1/reminders", 1)).toEqual({ offsets: [1, 0] });
    await waitFor(() => expect(screen.getByTestId("reminders-status")).toHaveTextContent("Reminders saved."));
    expect(week).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "1 day before" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "On the day" })).toBeChecked();
  });

  it("a failed save reverts the checkbox and announces an error", async () => {
    go("#/b/1");
    const { user } = mount({
      ...OWNER_DETAIL,
      "PUT /api/birthdays/1/reminders": () => json({ error: "boom" }, 500),
    });
    const day = await screen.findByRole("checkbox", { name: "On the day" });
    await waitFor(() => expect(day).toBeEnabled());
    await user.click(day);
    await waitFor(() =>
      expect(
        screen
          .getAllByRole("alert")
          .map((el) => el.textContent)
          .join(" "),
      ).toMatch(/Couldn't save your reminders\./),
    );
    expect(day).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "1 week before" })).toBeChecked();
  });

  it("names the reminders group My reminders, with the hint as its description", async () => {
    go("#/b/1");
    mount(OWNER_DETAIL);
    const group = await screen.findByRole("group", { name: "My reminders" });
    expect(group).toHaveAccessibleDescription(/Only you get these\./);
  });

  it("unticking the last reminder sends an empty list and turns the list's bell off", async () => {
    go("#/b/2");
    const belled = { ...ADA, reminder_offsets: [1] };
    const { user } = mount({
      "GET /api/birthdays/2": () => json({ birthday: belled, shares: [], gifts: [] }),
      "GET /api/birthdays": () => json({ birthdays: [SAM, belled, ZED] }),
      "PUT /api/birthdays/2/reminders": () => json({ offsets: [] }),
    });
    const day = await screen.findByRole("checkbox", { name: "1 day before" });
    await waitFor(() => expect(day).toBeEnabled());
    expect(day).toBeChecked();
    await user.click(day);
    await waitFor(() => expect(screen.getByTestId("reminders-status")).toHaveTextContent("Reminders saved."));
    expect(bodyOf("PUT /api/birthdays/2/reminders")).toEqual({ offsets: [] });
    expect(day).not.toBeChecked();
    expect(screen.getByText(/Untick all of them to turn reminders off/)).toBeInTheDocument();
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    const link = await screen.findByRole("link", { name: "Ada Lovelace" });
    expect(link.closest("li")).not.toHaveTextContent("Reminders on");
  });

  it("the list's bell follows the response", async () => {
    go("#/b/3");
    const { user } = mount({
      ...RECIPIENT_DETAIL,
      "PUT /api/birthdays/3/reminders": () => json({ offsets: [1] }),
    });
    const day = await screen.findByRole("checkbox", { name: "1 day before" });
    await waitFor(() => expect(day).toBeEnabled());
    await user.click(day);
    await waitFor(() => expect(screen.getByTestId("reminders-status")).toHaveTextContent("Reminders saved."));
    expect(bodyOf("PUT /api/birthdays/3/reminders")).toEqual({ offsets: [1] });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    const link = await screen.findByRole("link", { name: "Zed Young" });
    expect(link.closest("li")).toHaveTextContent("Reminders on");
  });

  it("shows the no-place-to-send notice above the checkboxes", async () => {
    go("#/b/1");
    mount(OWNER_DETAIL, { ...SETTINGS, ntfy: false, destinations: 0 });
    const section = (await screen.findByRole("heading", { name: "My reminders" })).closest("section");
    await waitFor(() => expect(within(section as HTMLElement).getByText(/nowhere to go/)).toBeInTheDocument());
    expect(within(section as HTMLElement).getByRole("link", { name: /Settings/ })).toHaveAttribute("href", "#/settings");
  });
});

describe("failures", () => {
  it("a detail 404 shows the panel and drops the row from the loaded list", async () => {
    go("#/b/3");
    const { user } = mount({ "GET /api/birthdays/3": () => json({ error: "not_found" }, 404) });
    await screen.findByRole("heading", { level: 2, name: "Birthday not found" });
    await user.click(within(nav()).getByRole("link", { name: /Birthdays/ }));
    await screen.findByRole("link", { name: "Ada Lovelace" });
    expect(screen.queryByRole("link", { name: "Zed Young" })).not.toBeInTheDocument();
  });

  it("a session-expired detail GET leaves no skeleton behind the banner", async () => {
    go("#/b/1");
    mount({ "GET /api/birthdays/1": () => html(200) });
    expect(await screen.findByText(/Your sign-in has expired/)).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByText(/Loading birthday/)).not.toBeInTheDocument());
  });

  it("session expiry keeps the edit draft and the banner promises it", async () => {
    window.sessionStorage.setItem(
      "birthdays:edit-draft:1",
      JSON.stringify({ name: "Sammy", month: 11, day: "16", year: "1990", email: EMAIL }),
    );
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "POST /api/birthdays/1/gifts": () => html(200) });
    await screen.findByText("Unsaved changes restored.");
    const input = screen.getByLabelText("New gift idea");
    await waitFor(() => expect(input).toBeEnabled());
    await user.type(input, "Scarf");
    await user.click(screen.getByRole("button", { name: "Add idea" }));
    expect(await screen.findByText(/Your birthday details are still here/)).toBeInTheDocument();
    expect(screen.getByDisplayValue("Sammy")).toBeInTheDocument();
    expect(window.sessionStorage.getItem("birthdays:edit-draft:1")).toContain("Sammy");
  });

  it("session expiry without a dirty edit promises nothing", async () => {
    go("#/b/1");
    const { user } = mount({ ...OWNER_DETAIL, "POST /api/birthdays/1/gifts": () => html(200) });
    const input = await screen.findByLabelText("New gift idea");
    await waitFor(() => expect(input).toBeEnabled());
    await user.type(input, "Scarf");
    await user.click(screen.getByRole("button", { name: "Add idea" }));
    expect(await screen.findByText(/Reload to sign in again\./)).toBeInTheDocument();
    expect(screen.queryByText(/still here/)).not.toBeInTheDocument();
  });
});
