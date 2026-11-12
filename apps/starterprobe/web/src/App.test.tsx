import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { Item } from "./api";

type Handler = () => Response | Promise<Response>;
type Routes = Record<string, Handler>;

const JSON_CT = { "Content-Type": "application/json" };
const HTML_CT = { "Content-Type": "text/html" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_CT });
}
function html(status: number): Response {
  return new Response("<html>edge</html>", { status, headers: HTML_CT });
}
function item(id: number, text = `note ${id}`, source = "user"): Item {
  return { id, text, created_by: "alex@example.com", source, created_at: "2026-11-07T14:32:00Z" };
}
function items(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => item(n - i));
}
function deferred() {
  let resolve!: (r: Response) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const ME: Handler = () => json({ email: "alex@example.com" });
const LIST = (list: Item[]): Handler => () => json({ items: list });
const TASK_OK: Handler = () => json({ id: "01ABC" }, 202);

let calls: string[] = [];

function mount(routes: Routes) {
  calls = [];
  const table: Routes = { "GET /api/me": ME, "GET /api/items": LIST([]), ...routes };
  vi.stubGlobal(
    "fetch",
    vi.fn((path: string, init?: RequestInit) => {
      const key = `${init?.method ?? "GET"} ${path}`;
      calls.push(key);
      const h = table[key];
      return Promise.resolve(h ? h() : html(404));
    }),
  );
  return { user: userEvent.setup(), ...render(<App />) };
}

function count(key: string): number {
  return calls.filter((c) => c === key).length;
}
const input = () => screen.getByLabelText("New note");
const addButton = () => screen.getByRole("button", { name: "Add" });
const taskButton = () => screen.getByRole("button", { name: "Run background task" });
const addStatus = () => screen.getByTestId("add-status");
const taskStatus = () => screen.getByTestId("task-status");
const addAlert = () => screen.getByTestId("add-alert");
const taskAlert = () => screen.getByTestId("task-alert");

// Counts how many times `message` is newly inserted into `el`, i.e. how many times a screen reader would announce it.
function watchAnnouncements(el: HTMLElement, message: string) {
  let n = 0;
  const obs = new MutationObserver((records) => {
    for (const r of records) {
      n += [...r.addedNodes].filter((node) => node.textContent === message).length;
    }
  });
  obs.observe(el, { childList: true, subtree: true, characterData: true });
  return () => {
    n += obs.takeRecords().flatMap((r) => [...r.addedNodes]).filter((node) => node.textContent === message).length;
    obs.disconnect();
    return n;
  };
}

async function loaded() {
  await screen.findByText("Signed in as", { exact: false });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("loading, empty and error copy", () => {
  it("shows loading copy, a busy list and disables the form and task button until sign-in resolves", async () => {
    const me = deferred();
    const list = deferred();
    mount({ "GET /api/me": () => me.promise, "GET /api/items": () => list.promise });
    expect(screen.getByText("Checking sign-in…")).toBeInTheDocument();
    expect(screen.getByLabelText("Loading notes")).toHaveAttribute("aria-busy", "true");
    expect(input()).toBeDisabled();
    expect(addButton()).toBeDisabled();
    expect(taskButton()).toBeDisabled();
    expect(screen.queryByText("No notes yet. Add your first one above.")).not.toBeInTheDocument();
    me.resolve(json({ email: "alex@example.com" }));
    list.resolve(json({ items: [] }));
    await loaded();
    expect(input()).toBeEnabled();
    expect(taskButton()).toBeEnabled();
  });

  it("shows the app name as the single h1", async () => {
    mount({});
    await loaded();
    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("starterprobe");
  });

  it("shows the empty copy", async () => {
    mount({});
    expect(await screen.findByText("No notes yet. Add your first one above.")).toBeInTheDocument();
    expect(screen.queryByLabelText("Loading notes")).not.toBeInTheDocument();
  });

  it("shows a list error with Try again, and Try again recovers", async () => {
    let fail = true;
    const { user } = mount({ "GET /api/items": () => (fail ? json({ error: "internal" }, 500) : json({ items: [item(1)] })) });
    expect(await screen.findByText("Couldn't load your notes.")).toBeInTheDocument();
    fail = false;
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("note 1")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
  });

  it("shows Can't reach the app for a 503 down page, not a crash or blank list", async () => {
    mount({ "GET /api/items": () => html(503) });
    expect(await screen.findByText("Can't reach the app right now.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("lists notes with a <time datetime> and a Background task author", async () => {
    mount({ "GET /api/items": LIST([item(2, "from job", "job"), item(1)]) });
    expect(await screen.findByText("from job")).toBeInTheDocument();
    expect(screen.getByText("Background task", { selector: ".meta", exact: false })).toBeInTheDocument();
    const times = document.querySelectorAll("time");
    expect(times).toHaveLength(2);
    expect(times[0]).toHaveAttribute("datetime", "2026-11-07T14:32:00Z");
  });

  it("shows the 50-note line at 50 and 51 items but not at 49", async () => {
    mount({ "GET /api/items": LIST(items(49)) });
    await screen.findByText("note 49");
    expect(screen.queryByText("Showing the latest 50 notes.")).not.toBeInTheDocument();
  });

  it("shows the 50-note line at exactly 50 items", async () => {
    mount({ "GET /api/items": LIST(items(50)) });
    expect(await screen.findByText("Showing the latest 50 notes.")).toBeInTheDocument();
  });

  it("shows the 50-note line at 51 items", async () => {
    mount({ "GET /api/items": LIST(items(51)) });
    expect(await screen.findByText("Showing the latest 50 notes.")).toBeInTheDocument();
  });

  it("keeps the previous list rendered when a later fetch is unavailable", async () => {
    let down = false;
    const { user } = mount({
      "GET /api/items": () => (down ? html(503) : json({ items: [item(1, "kept note")] })),
      "POST /api/tasks": TASK_OK,
    });
    await screen.findByText("kept note");
    await user.click(taskButton());
    await screen.findByText(/^Queued\./);
    down = true;
    await user.click(screen.getByRole("button", { name: "Refresh notes" }));
    expect(await screen.findByText("Can't reach the app right now.")).toBeInTheDocument();
    expect(screen.getByText("kept note")).toBeInTheDocument();
  });
});

describe("header", () => {
  it("shows Sign-in status unavailable after a failed /api/me, without leaving Checking sign-in", async () => {
    mount({ "GET /api/me": () => html(503) });
    expect(await screen.findByText("Sign-in status unavailable")).toBeInTheDocument();
    expect(screen.queryByText("Checking sign-in…")).not.toBeInTheDocument();
    expect(input()).toBeEnabled();
  });

  it("shows Sign out and its hint in production", async () => {
    vi.stubEnv("DEV", false);
    mount({});
    await loaded();
    expect(screen.getByRole("link", { name: "Sign out" })).toHaveAttribute("href", "/cdn-cgi/access/logout");
    expect(screen.getByText("Signs you out of all family apps")).toBeInTheDocument();
    expect(screen.queryByText("(dev)", { exact: false })).not.toBeInTheDocument();
  });

  it("hides Sign out and its hint and appends (dev) when DEV is true", async () => {
    vi.stubEnv("DEV", true);
    mount({});
    await loaded();
    expect(screen.queryByRole("link", { name: "Sign out" })).not.toBeInTheDocument();
    expect(screen.queryByText("Signs you out of all family apps")).not.toBeInTheDocument();
    expect(screen.getByText("(dev)", { exact: false })).toBeInTheDocument();
  });
});

describe("adding a note", () => {
  it("clears and focuses the input and announces Note added., and a second add re-announces", async () => {
    let n = 0;
    const { user } = mount({
      "POST /api/items": () => json(item(++n, "x"), 201),
    });
    await loaded();
    const done = watchAnnouncements(addStatus(), "Note added.");
    await user.type(input(), "first");
    await user.click(addButton());
    await waitFor(() => expect(addStatus()).toHaveTextContent("Note added."));
    expect(input()).toHaveValue("");
    expect(input()).toHaveFocus();
    await user.type(input(), "second");
    await user.click(addButton());
    await waitFor(() => expect(count("POST /api/items")).toBe(2));
    await waitFor(() => expect(addStatus()).toHaveTextContent("Note added."));
    expect(done()).toBe(2);
  });

  it("sends no request for an empty or whitespace note, focuses the input and shows the inline error", async () => {
    const { user } = mount({});
    await loaded();
    await user.click(addButton());
    expect(count("POST /api/items")).toBe(0);
    expect(screen.getByText("Write something first (up to 200 characters).", { selector: "#newnote-err" })).toBeInTheDocument();
    expect(input()).toHaveAttribute("aria-invalid", "true");
    expect(input()).toHaveAttribute("aria-describedby", "newnote-err");
    expect(input()).toHaveFocus();
    await user.type(input(), "   ");
    await user.click(addButton());
    expect(count("POST /api/items")).toBe(0);
  });

  it("re-announces a repeated invalid submit in the status region", async () => {
    const { user } = mount({});
    await loaded();
    const done = watchAnnouncements(addStatus(), "Write something first (up to 200 characters).");
    await user.click(addButton());
    await user.click(addButton());
    expect(addStatus()).toHaveTextContent("Write something first");
    expect(done()).toBe(2);
  });

  it("clears the inline error on input change and on success", async () => {
    let accept = false;
    const { user } = mount({
      "POST /api/items": () => (accept ? json(item(1, "ok"), 201) : json({ error: "invalid_text" }, 400)),
    });
    await loaded();
    await user.click(addButton());
    expect(input()).toHaveAttribute("aria-invalid", "true");
    await user.type(input(), "a");
    expect(input()).not.toHaveAttribute("aria-invalid");
    expect(screen.queryByText("Write something first (up to 200 characters).", { selector: "#newnote-err" })).not.toBeInTheDocument();
    // Success: the server rejects once (error shown, text kept), then accepts the resubmit with no edit in between.
    await user.click(addButton());
    await screen.findByText("Write something first (up to 200 characters).", { selector: "#newnote-err" });
    accept = true;
    await user.click(addButton());
    await waitFor(() => expect(addStatus()).toHaveTextContent("Note added."));
    expect(input()).not.toHaveAttribute("aria-invalid");
    expect(screen.queryByText("Write something first (up to 200 characters).", { selector: "#newnote-err" })).not.toBeInTheDocument();
  });

  it("uses aria-disabled, not disabled, and sends no second request while pending; announces Adding…", async () => {
    const post = deferred();
    const { user } = mount({ "POST /api/items": () => post.promise });
    await loaded();
    await user.type(input(), "slow");
    await user.click(addButton());
    await waitFor(() => expect(addStatus()).toHaveTextContent("Adding…"));
    expect(addButton()).toHaveAttribute("aria-disabled", "true");
    expect(addButton()).not.toBeDisabled();
    expect(addButton()).toHaveFocus();
    await user.click(addButton());
    expect(count("POST /api/items")).toBe(1);
    post.resolve(json(item(1, "slow"), 201));
    await waitFor(() => expect(addStatus()).toHaveTextContent("Note added."));
    expect(addButton()).not.toHaveAttribute("aria-disabled");
  });

  it("keeps the typed text, focuses the input and shows the error in the add alert area on a failed add", async () => {
    const { user } = mount({ "POST /api/items": () => html(503) });
    await loaded();
    await user.type(input(), "keep me");
    await user.click(addButton());
    await waitFor(() => expect(addAlert()).toHaveTextContent("Can't reach the app right now. Try again in a minute."));
    expect(input()).toHaveValue("keep me");
    expect(input()).toBeEnabled();
    expect(input()).toHaveFocus();
    expect(addStatus()).toHaveTextContent("");
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
  });

  it("shows the generic message for a JSON 500 on add", async () => {
    const { user } = mount({ "POST /api/items": () => json({ error: "internal" }, 500) });
    await loaded();
    await user.type(input(), "x");
    await user.click(addButton());
    await waitFor(() => expect(addAlert()).toHaveTextContent("Something went wrong on our side."));
    expect(screen.queryByText("internal")).not.toBeInTheDocument();
  });

  it("shows the server's invalid_text as the inline error", async () => {
    const { user } = mount({ "POST /api/items": () => json({ error: "invalid_text" }, 400) });
    await loaded();
    await user.type(input(), "x");
    await user.click(addButton());
    expect(await screen.findByText("Write something first (up to 200 characters).", { selector: "#newnote-err" })).toBeInTheDocument();
    expect(input()).toHaveValue("x");
  });

  it("prepends the new note during listerror and then re-fetches", async () => {
    const refetch = deferred();
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? json({ error: "internal" }, 500) : refetch.promise),
      "POST /api/items": () => json(item(7, "fresh"), 201),
    });
    await screen.findByText("Couldn't load your notes.");
    await user.type(input(), "fresh");
    await user.click(addButton());
    // Shown from the 201 alone, while the re-fetch is still pending.
    expect(await screen.findByText("fresh")).toBeInTheDocument();
    await waitFor(() => expect(count("GET /api/items")).toBe(2));
    expect(screen.queryByText("older")).not.toBeInTheDocument();
    refetch.resolve(json({ items: [item(7, "fresh"), item(1, "older")] }));
    expect(await screen.findByText("older")).toBeInTheDocument();
    expect(screen.queryByText("Couldn't load your notes.")).not.toBeInTheDocument();
  });

  it("keeps the list with the new note under the alert when the re-fetch after an add fails", async () => {
    let first = true;
    const { user } = mount({
      "GET /api/items": () => {
        if (first) {
          first = false;
          return json({ items: [item(1, "older")] });
        }
        return html(503);
      },
      "POST /api/items": () => json(item(2, "newest"), 201),
    });
    await screen.findByText("older");
    await user.type(input(), "newest");
    await user.click(addButton());
    expect(await screen.findByText("Can't reach the app right now.")).toBeInTheDocument();
    expect(screen.getByText("newest")).toBeInTheDocument();
    expect(screen.getByText("older")).toBeInTheDocument();
  });

  it("shows 51 items with the 50-note line after a prepended add", async () => {
    let gets = 0;
    const { user } = mount({
      "GET /api/items": () => (++gets === 1 ? json({ items: items(50) }) : html(503)),
      "POST /api/items": () => json(item(99, "extra"), 201),
    });
    await screen.findByText("Showing the latest 50 notes.");
    await user.type(input(), "extra");
    await user.click(addButton());
    await screen.findByText("extra");
    expect(screen.getByText("Showing the latest 50 notes.")).toBeInTheDocument();
    expect(document.querySelectorAll("ul.items li")).toHaveLength(51);
  });
});

describe("list ordering", () => {
  it("never lets a slower earlier list response overwrite a newer one", async () => {
    const initial = deferred();
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? initial.promise : json({ items: [item(2, "newer")] })),
      "POST /api/tasks": TASK_OK,
    });
    await loaded();
    await user.click(taskButton());
    await user.click(await screen.findByRole("button", { name: "Refresh notes" }));
    await screen.findByText("newer");
    await act(async () => {
      initial.resolve(json({ items: [item(1, "older")] }));
      await new Promise((r) => setTimeout(r, 20));
    });
    expect(screen.queryByText("older")).not.toBeInTheDocument();
    expect(screen.getByText("newer")).toBeInTheDocument();
  });
});

describe("background task", () => {
  it("announces Queuing…, uses aria-disabled while pending, then re-enables the button and keeps Queued.", async () => {
    const post = deferred();
    const { user } = mount({ "POST /api/tasks": () => post.promise });
    await loaded();
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queuing…"));
    expect(taskButton()).toHaveAttribute("aria-disabled", "true");
    expect(taskButton()).not.toBeDisabled();
    expect(taskButton()).toHaveFocus();
    await user.click(taskButton());
    expect(count("POST /api/tasks")).toBe(1);
    post.resolve(json({ id: "01ABC" }, 202));
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued. It will show up in your notes in a few seconds."));
    expect(taskButton()).not.toHaveAttribute("aria-disabled");
    expect(screen.getByRole("button", { name: "Refresh notes" })).toBeInTheDocument();
  });

  it("shows busy in the separate alert, keeps the status node role and the button enabled, and clears busy at the next enqueue", async () => {
    let busy = true;
    const post = deferred();
    const { user } = mount({
      "POST /api/tasks": () => (busy ? json({ error: "queue_full" }, 429) : post.promise),
    });
    await loaded();
    await user.click(taskButton());
    await waitFor(() =>
      expect(taskAlert()).toHaveTextContent("Too many background tasks are waiting. Try again in a few minutes."),
    );
    expect(taskAlert()).toHaveAttribute("role", "alert");
    expect(taskStatus()).toHaveAttribute("role", "status");
    expect(taskButton()).toBeEnabled();
    expect(taskButton()).not.toHaveAttribute("aria-disabled");
    expect(input()).toBeEnabled();
    expect(addButton()).toBeEnabled();
    busy = false;
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queuing…"));
    expect(taskAlert()).toHaveTextContent("");
    post.resolve(json({ id: "x" }, 202));
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued."));
  });

  it("renders a failed enqueue in the task alert with Queuing… cleared and no Try again button", async () => {
    const { user } = mount({ "POST /api/tasks": () => html(503) });
    await loaded();
    await user.click(taskButton());
    await waitFor(() => expect(taskAlert()).toHaveTextContent("Can't reach the app right now."));
    expect(taskStatus()).toHaveTextContent("");
    expect(taskButton()).toBeEnabled();
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
  });

  it("keeps focus on Refresh notes, announces Notes refreshed. and clears Queued.", async () => {
    const { user } = mount({ "POST /api/tasks": TASK_OK });
    await loaded();
    await user.click(taskButton());
    const refresh = await screen.findByRole("button", { name: "Refresh notes" });
    await user.click(refresh);
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Notes refreshed."));
    expect(taskStatus()).not.toHaveTextContent("Queued.");
    expect(refresh).toHaveFocus();
    expect(refresh).not.toHaveAttribute("aria-disabled");
    expect(screen.getByRole("button", { name: "Refresh notes" })).toBeInTheDocument();
  });

  it("uses aria-disabled on Refresh notes while its fetch runs", async () => {
    const refreshFetch = deferred();
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? json({ items: [] }) : refreshFetch.promise),
      "POST /api/tasks": TASK_OK,
    });
    await loaded();
    await user.click(taskButton());
    const refresh = await screen.findByRole("button", { name: "Refresh notes" });
    await user.click(refresh);
    expect(refresh).toHaveAttribute("aria-disabled", "true");
    await user.click(refresh);
    expect(count("GET /api/items")).toBe(2);
    refreshFetch.resolve(json({ items: [] }));
    await waitFor(() => expect(refresh).not.toHaveAttribute("aria-disabled"));
  });

  it("does not announce Notes refreshed. after a failed refresh", async () => {
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? json({ items: [item(1)] }) : json({ error: "internal" }, 500)),
      "POST /api/tasks": TASK_OK,
    });
    await screen.findByText("note 1");
    await user.click(taskButton());
    await user.click(await screen.findByRole("button", { name: "Refresh notes" }));
    await screen.findByText("Couldn't load your notes.");
    expect(taskStatus()).toHaveTextContent("");
    expect(screen.getByText("note 1")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh notes" })).toBeInTheDocument();
  });

  it("clears Queued. on a later add", async () => {
    const { user } = mount({ "POST /api/tasks": TASK_OK, "POST /api/items": () => json(item(1, "n"), 201) });
    await loaded();
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued."));
    await user.type(input(), "n");
    await user.click(addButton());
    await waitFor(() => expect(addStatus()).toHaveTextContent("Note added."));
    expect(taskStatus()).toHaveTextContent("");
  });

  it("clears Queued. at the start of a later enqueue", async () => {
    let n = 0;
    const second = deferred();
    const { user } = mount({ "POST /api/tasks": () => (++n === 1 ? json({ id: "a" }, 202) : second.promise) });
    await loaded();
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued."));
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queuing…"));
    expect(taskStatus()).not.toHaveTextContent("Queued.");
    second.resolve(json({ id: "b" }, 202));
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued."));
  });
});

describe("states that keep the form usable", () => {
  it("leaves the form and task button enabled for unavailable, listerror, busy and queued", async () => {
    mount({ "GET /api/items": () => html(503) });
    await screen.findByText("Can't reach the app right now.");
    expect(input()).toBeEnabled();
    expect(addButton()).toBeEnabled();
    expect(taskButton()).toBeEnabled();
  });

  it("leaves the form and task button enabled for a list error", async () => {
    mount({ "GET /api/items": () => json({ error: "internal" }, 500) });
    await screen.findByText("Couldn't load your notes.");
    expect(input()).toBeEnabled();
    expect(addButton()).toBeEnabled();
    expect(taskButton()).toBeEnabled();
  });

  it("leaves the form and task button enabled when queued", async () => {
    const { user } = mount({ "POST /api/tasks": TASK_OK });
    await loaded();
    await user.click(taskButton());
    await waitFor(() => expect(taskStatus()).toHaveTextContent("Queued."));
    expect(input()).toBeEnabled();
    expect(addButton()).toBeEnabled();
    expect(taskButton()).toBeEnabled();
  });
});

describe("expired and unconfirmed sign-in", () => {
  it("shows the Reload banner for a non-JSON 401, disables the form, hides the task section and focuses Reload", async () => {
    mount({ "GET /api/me": () => html(401), "GET /api/items": () => html(401) });
    const reload = await screen.findByRole("button", { name: "Reload" });
    expect(screen.getByText("Your sign-in has expired.")).toBeInTheDocument();
    expect(screen.queryByText("We couldn't confirm your sign-in.")).not.toBeInTheDocument();
    expect(input()).toBeDisabled();
    expect(addButton()).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Run background task" })).not.toBeInTheDocument();
    expect(screen.queryByText("Background task")).not.toBeInTheDocument();
    expect(reload).toHaveFocus();
    expect(screen.queryByText("Checking sign-in…")).not.toBeInTheDocument();
  });

  it("shows the couldn't-confirm banner for a JSON 401 unauthenticated and focuses Reload", async () => {
    mount({
      "GET /api/me": () => json({ error: "unauthenticated" }, 401),
      "GET /api/items": () => json({ error: "unauthenticated" }, 401),
    });
    const reload = await screen.findByRole("button", { name: "Reload" });
    expect(screen.getByText("We couldn't confirm your sign-in.")).toBeInTheDocument();
    expect(screen.queryByText("Your sign-in has expired.")).not.toBeInTheDocument();
    expect(input()).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Run background task" })).not.toBeInTheDocument();
    expect(reload).toHaveFocus();
  });

  it("keeps the last list read-only, the typed text and no identity on a mid-session 401 from an add", async () => {
    const { user } = mount({
      "GET /api/items": LIST([item(1, "still here")]),
      "POST /api/items": () => html(401),
    });
    await screen.findByText("still here");
    await user.type(input(), "typed text");
    await user.click(addButton());
    await screen.findByText("Your sign-in has expired.");
    expect(screen.getByText("still here")).toBeInTheDocument();
    expect(input()).toHaveValue("typed text");
    expect(input()).toBeDisabled();
    expect(screen.queryByText("Signed in as", { exact: false })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Run background task" })).not.toBeInTheDocument();
    expect(addAlert()).toHaveTextContent("");
    expect(screen.getByRole("button", { name: "Reload" })).toHaveFocus();
  });

  it("keeps the last list and hides the task section on a mid-session 403 from Refresh notes", async () => {
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? json({ items: [item(1, "listed")] }) : html(403)),
      "POST /api/tasks": TASK_OK,
    });
    await screen.findByText("listed");
    await user.click(taskButton());
    await user.click(await screen.findByRole("button", { name: "Refresh notes" }));
    await screen.findByText("Your sign-in has expired.");
    expect(screen.getByText("listed")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Refresh notes" })).not.toBeInTheDocument();
    expect(screen.queryByText("Signed in as", { exact: false })).not.toBeInTheDocument();
  });

  it("shows the banner on a mid-session failed task POST", async () => {
    const { user } = mount({ "POST /api/tasks": () => json({ error: "unauthenticated" }, 401) });
    await loaded();
    await user.click(taskButton());
    expect(await screen.findByText("We couldn't confirm your sign-in.")).toBeInTheDocument();
    expect(within(document.body).queryByTestId("task-alert")).not.toBeInTheDocument();
    expect(input()).toBeDisabled();
    expect(screen.getByRole("button", { name: "Reload" })).toHaveFocus();
  });

  it("keeps the last list and typed text on a mid-session JSON 401 (noidentity) from an add", async () => {
    const { user } = mount({
      "GET /api/items": LIST([item(1, "kept")]),
      "POST /api/items": () => json({ error: "unauthenticated" }, 401),
    });
    await screen.findByText("kept");
    await user.type(input(), "typed");
    await user.click(addButton());
    await screen.findByText("We couldn't confirm your sign-in.");
    expect(screen.getByText("kept")).toBeInTheDocument();
    expect(input()).toHaveValue("typed");
    expect(input()).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Run background task" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reload" })).toHaveFocus();
  });

  it("keeps the typed text and disabled input on a mid-session 403 from Refresh notes", async () => {
    let n = 0;
    const { user } = mount({
      "GET /api/items": () => (++n === 1 ? json({ items: [item(1, "listed")] }) : html(403)),
      "POST /api/tasks": TASK_OK,
    });
    await screen.findByText("listed");
    await user.type(input(), "draft");
    await user.click(taskButton());
    await user.click(await screen.findByRole("button", { name: "Refresh notes" }));
    await screen.findByText("Your sign-in has expired.");
    expect(input()).toHaveValue("draft");
    expect(input()).toBeDisabled();
  });

  it("shows the page-level banner and keeps the list when /api/me fails with a JSON 401 while the list loaded", async () => {
    mount({
      "GET /api/me": () => json({ error: "unauthenticated" }, 401),
      "GET /api/items": LIST([item(1, "cached")]),
    });
    await screen.findByText("We couldn't confirm your sign-in.");
    expect(await screen.findByText("cached")).toBeInTheDocument();
    expect(input()).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Run background task" })).not.toBeInTheDocument();
  });
});
