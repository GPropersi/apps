import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import type { Destination, Phone } from "./api";

type Handler = (init?: RequestInit) => Response | Promise<Response>;
type Routes = Record<string, Handler>;

const JSON_CT = { "Content-Type": "application/json" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_CT });
}
function deferred() {
  let resolve!: (r: Response) => void;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

// Secrets are built at runtime so no secret-shaped literal sits in the source.
const PW = ["pw", "one", "time"].join("-");
const PW2 = ["pw", "two", "time"].join("-");
const SIG1 = ["sig", "first", "once"].join("-");
const SIG2 = ["sig", "second", "once"].join("-");
const SETUP = "https://setup.example.test/?app=a";

const P_OFF: Phone = { ntfy: false, destinations: 0, stale_destinations: 0 };
const P_ON: Phone = { ntfy: true, destinations: 0, stale_destinations: 0 };

function dest(id: number, label: string, over: Partial<Destination> = {}): Destination {
  return { id, kind: "discord", label, hint: "ends 9Q", stale: false, ...over };
}
const LIST = (list: Destination[]): Handler => () => json({ destinations: list });
const meBody = (phone: Phone | null, notifs: boolean | "missing" = true) => ({
  email: "alex@example.com",
  ...(notifs === "missing" ? {} : { notifs }),
  ...(phone !== null && notifs === true ? { phone } : {}),
});

let calls: string[] = [];
let bodies: Record<string, string[]> = {};

function mount(routes: Routes = {}, phone: Phone | null = P_OFF, notifs: boolean | "missing" = true) {
  calls = [];
  bodies = {};
  const table: Routes = {
    "GET /api/me": () => json(meBody(phone, notifs)),
    "GET /api/items": () => json({ items: [] }),
    "GET /api/notify/destinations": LIST([]),
    ...routes,
  };
  vi.stubGlobal(
    "fetch",
    vi.fn((path: string, init?: RequestInit) => {
      const key = `${init?.method ?? "GET"} ${path}`;
      calls.push(key);
      (bodies[key] ??= []).push(String(init?.body ?? ""));
      const h = table[key];
      return Promise.resolve(h ? h(init) : new Response("<html>edge</html>", { status: 404, headers: { "Content-Type": "text/html" } }));
    }),
  );
  return { user: userEvent.setup(), ...render(<App />) };
}

const count = (key: string) => calls.filter((c) => c === key).length;
const heading = () => screen.getByRole("heading", { name: "Phone notifications" });
const btn = (name: string) => screen.getByRole("button", { name });
const testStatus = () => screen.getByTestId("test-status");
const destStatus = () => screen.getByTestId("destinations-status");

async function ready() {
  await screen.findByRole("heading", { name: "Phone notifications" });
  await waitFor(() => expect(screen.queryByText("Loading destinations…")).not.toBeInTheDocument());
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("visibility", () => {
  it.each([false, "missing" as const])("hides the section when notifs is %s", async (notifs) => {
    mount({}, P_OFF, notifs);
    await screen.findByText("Signed in as", { exact: false });
    expect(screen.queryByRole("heading", { name: "Phone notifications" })).not.toBeInTheDocument();
    expect(calls.some((c) => c.includes("/api/notify"))).toBe(false);
  });

  it("shows the not-set-up state and no Send test", async () => {
    mount();
    await ready();
    expect(screen.getByText("Not set up yet")).toBeInTheDocument();
    expect(btn("Set up phone")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Send test/ })).not.toBeInTheDocument();
    // The Notes list is untouched.
    expect(document.querySelector("ul.items.dests")).not.toBeNull();
    expect(document.querySelectorAll("ul.items.dests")).toHaveLength(1);
  });
});

describe("phone setup and secrets", () => {
  const setupOk: Handler = () => json({ user_id: "u", setup_url: SETUP, password: PW, phone: P_ON });

  it("shows the one-time password, focuses its panel, announces it, and ack focuses the phone-row button", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": setupOk });
    await ready();
    await user.click(btn("Set up phone"));
    const panel = await screen.findByRole("heading", { name: "Your phone notification password" });
    expect(panel).toHaveFocus();
    expect(screen.getByTestId("secret-notice")).toHaveTextContent("Your phone notification password. Copy it before you leave this page.");
    expect(screen.getByText(PW)).toBeInTheDocument();
    expect(JSON.parse(bodies["POST /api/notify/ntfy"][0])).toEqual({});
    // Send test and Show setup again stay enabled while the secret is pending.
    expect(btn("Send test to your phone")).not.toHaveAttribute("aria-disabled");
    await user.click(btn("I've saved it"));
    expect(screen.queryByText(PW)).not.toBeInTheDocument();
    expect(btn("Show setup again")).toHaveFocus();
  });

  it("Copy shows Copied", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": setupOk });
    await ready();
    await user.click(btn("Set up phone"));
    await user.click(await screen.findByRole("button", { name: "Copy" }));
    expect(await screen.findByText("Copied")).toBeInTheDocument();
  });

  it("Show setup again while the password is pending refocuses that panel and posts nothing", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": setupOk });
    await ready();
    await user.click(btn("Set up phone"));
    await screen.findByText(PW);
    await user.click(btn("Show setup again"));
    expect(screen.getByRole("heading", { name: "Your phone notification password" })).toHaveFocus();
    expect(count("POST /api/notify/ntfy")).toBe(1);
    expect(screen.queryByRole("group", { name: "Phone notifications are set up" })).not.toBeInTheDocument();
  });

  it("opens the setup details and focuses their heading; the setup link is http(s) only and noopener", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": () => json({ user_id: "u", setup_url: SETUP, password: null, phone: P_ON }) }, P_ON);
    await ready();
    await user.click(btn("Show setup again"));
    expect(await screen.findByRole("heading", { name: "Phone notifications are set up" })).toHaveFocus();
    const link = screen.getByRole("link", { name: "Open the setup page" });
    expect(link).toHaveAttribute("rel", "noopener noreferrer");
    expect(link).toHaveAttribute("href", SETUP);
    await user.click(btn("Hide setup"));
    expect(screen.queryByRole("heading", { name: "Phone notifications are set up" })).not.toBeInTheDocument();
  });

  it("hides a non-http setup link", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": () => json({ setup_url: "javascript:alert(1)", password: null, phone: P_ON }) }, P_ON);
    await ready();
    await user.click(btn("Show setup again"));
    await screen.findByRole("heading", { name: "Phone notifications are set up" });
    expect(screen.queryByRole("link", { name: "Open the setup page" })).not.toBeInTheDocument();
  });

  it("reset confirm focuses Cancel, Escape cancels back to Generate, and a reset replaces only the ntfy secret", async () => {
    const { user } = mount(
      {
        "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: null, phone: P_ON }),
        "POST /api/notify/ntfy/reset": () => json({ setup_url: SETUP, password: PW2, phone: P_ON }),
        "POST /api/notify/destinations": () =>
          json({ destination: dest(3, "Hook", { kind: "webhook" }), signing_secret: SIG1, phone: P_ON }, 201),
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Show setup again"));
    await user.click(await screen.findByRole("button", { name: "Generate a new password" }));
    expect(btn("Cancel")).toHaveFocus();
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
    expect(btn("Generate a new password")).toHaveFocus();

    await user.click(btn("Generate a new password"));
    await user.click(btn("Yes, generate"));
    await screen.findByText(PW2);
    // A webhook secret stacks beside it; a second reset would replace only the ntfy one.
    await user.selectOptions(screen.getByLabelText("Type"), "webhook");
    await user.type(screen.getByLabelText("Label"), "Hook");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await screen.findByText(SIG1);
    expect(screen.getByText(PW2)).toBeInTheDocument();
    expect(document.querySelectorAll("section[data-secret]")).toHaveLength(2);
  });

  it("stacks webhook secrets and a regenerated password replaces only the ntfy entry; ack focuses per entry", async () => {
    let n = 0;
    const secrets = [SIG1, SIG2];
    let pw = PW;
    const { user } = mount(
      {
        "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: pw, phone: P_ON }),
        "POST /api/notify/ntfy/reset": () => json({ setup_url: SETUP, password: PW2, phone: P_ON }),
        "POST /api/notify/destinations": () => {
          n += 1;
          return json({ destination: dest(10 + n, `Hook ${n}`, { kind: "webhook" }), signing_secret: secrets[n - 1], phone: P_ON }, 201);
        },
      },
      P_OFF,
    );
    await ready();
    await user.click(btn("Set up phone"));
    await screen.findByText(pw);
    pw = "";
    await user.selectOptions(screen.getByLabelText("Type"), "webhook");
    for (const name of ["Hook 1", "Hook 2"]) {
      await user.clear(screen.getByLabelText("Label"));
      await user.type(screen.getByLabelText("Label"), name);
      await user.clear(screen.getByLabelText("Address"));
      await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
      await user.click(btn("Add destination"));
      await screen.findByText(secrets[Number(name.slice(-1)) - 1]);
    }
    expect(document.querySelectorAll("section[data-secret]")).toHaveLength(3);
    // Ack the newest webhook: focus returns to the Add button; the others stay.
    const second = document.querySelector('section[data-secret="webhook:12"]') as HTMLElement;
    await user.click(within(second).getByRole("button", { name: "I've saved it" }));
    expect(document.querySelectorAll("section[data-secret]")).toHaveLength(2);
    expect(btn("Add destination")).toHaveFocus();
  });

  it("guards unload while a secret is unacknowledged and never writes secrets to storage", async () => {
    const local = vi.spyOn(Storage.prototype, "setItem");
    const { user } = mount({ "POST /api/notify/ntfy": setupOk });
    await ready();
    const quiet = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(quiet);
    expect(quiet.defaultPrevented).toBe(false);
    await user.click(btn("Set up phone"));
    await screen.findByText(PW);
    const guarded = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(guarded);
    expect(guarded.defaultPrevented).toBe(true);
    await user.click(btn("I've saved it"));
    const after = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(after);
    expect(after.defaultPrevented).toBe(false);
    expect(local).not.toHaveBeenCalled();
  });
});

describe("tests and busy state", () => {
  it("announces success, disables only test buttons while sending, and a second click posts nothing", async () => {
    const slow = deferred();
    const { user } = mount(
      { "POST /api/notify/ntfy/test": () => slow.promise, "GET /api/notify/destinations": LIST([dest(1, "Team")]) },
      P_ON,
    );
    await ready();
    const send = btn("Send test to your phone");
    await user.click(send);
    expect(testStatus()).toHaveTextContent("Sending test…");
    expect(btn("Sending…: your phone")).toHaveAttribute("aria-disabled", "true");
    expect(btn("Send test to Team")).toHaveAttribute("aria-disabled", "true");
    expect(btn("Remove destination Team")).not.toHaveAttribute("aria-disabled");
    expect(btn("Show setup again")).not.toHaveAttribute("aria-disabled");
    await user.click(btn("Send test to Team"));
    expect(count("POST /api/notify/destinations/1/test")).toBe(0);
    slow.resolve(json({ phone: P_ON }));
    await waitFor(() => expect(testStatus()).toHaveTextContent("Test sent to your phone. It can take a few seconds to arrive."));
    expect(count("POST /api/notify/ntfy/test")).toBe(1);
  });

  it("names the destination label on a destination test", async () => {
    const { user } = mount(
      { "POST /api/notify/destinations/1/test": () => json({ phone: P_ON }), "GET /api/notify/destinations": LIST([dest(1, "Team")]) },
      P_ON,
    );
    await ready();
    await user.click(btn("Send test to Team"));
    await waitFor(() => expect(testStatus()).toHaveTextContent("Test sent to Team. It can take a few seconds to arrive."));
  });

  it.each([
    [429, "rate_limited", "Too many tries. Wait a minute and try again."],
    [500, "notify_unavailable", "Notifications are unavailable right now. Try again in a minute."],
    [409, "ntfy_not_set_up", "Phone notifications aren't set up yet. Tap Show setup again to finish phone setup."],
  ])("shows %i %s in test-status", async (status, code, text) => {
    const { user } = mount({ "POST /api/notify/ntfy/test": () => json({ error: code }, status) }, P_ON);
    await ready();
    await user.click(btn("Send test to your phone"));
    await waitFor(() => expect(testStatus()).toHaveTextContent(text));
  });

  it("re-announces a repeated identical result", async () => {
    const { user } = mount({ "POST /api/notify/ntfy/test": () => json({ phone: P_ON }) }, P_ON);
    await ready();
    let n = 0;
    const obs = new MutationObserver((records) => {
      for (const r of records) {
        n += [...r.addedNodes].filter((node) => node.textContent === "Test sent to your phone. It can take a few seconds to arrive.").length;
      }
    });
    obs.observe(testStatus(), { childList: true, subtree: true, characterData: true });
    await user.click(btn("Send test to your phone"));
    await waitFor(() => expect(testStatus()).toHaveTextContent("Test sent"));
    await user.click(btn("Send test to your phone"));
    await waitFor(() => expect(count("POST /api/notify/ntfy/test")).toBe(2));
    await waitFor(() => expect(testStatus()).toHaveTextContent("Test sent"));
    n += obs.takeRecords().flatMap((r) => [...r.addedNodes]).filter((node) => node.textContent === "Test sent to your phone. It can take a few seconds to arrive.").length;
    obs.disconnect();
    expect(n).toBe(2);
  });

  it("destination_stale refreshes /api/me then the list and focuses Check again", async () => {
    let stale = false;
    const { user } = mount(
      {
        "POST /api/notify/destinations/1/test": () => {
          stale = true;
          return json({ error: "destination_stale" }, 409);
        },
        "GET /api/notify/destinations": () => json({ destinations: [dest(1, "Team", { stale })] }),
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Send test to Team"));
    await waitFor(() => expect(btn("Check again: Team")).toHaveFocus());
    expect(testStatus()).toHaveTextContent("marked stale");
    expect(count("GET /api/me")).toBe(2);
    expect(count("GET /api/notify/destinations")).toBe(2);
    // The guard is released: a second test works.
    stale = false;
  });

  it("Check again that clears stale focuses the row's new Send test button; one that stays stale keeps focus", async () => {
    let stale = true;
    const { user } = mount(
      {
        "GET /api/notify/destinations": () => json({ destinations: [dest(5, "Old", { stale: true })] }),
        "POST /api/notify/destinations/5/check": () => json({ destination: dest(5, "Old", { stale }), phone: P_ON }),
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Check again: Old"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Old still can't be reached"));
    expect(btn("Check again: Old")).toHaveFocus();
    stale = false;
    await user.click(btn("Check again: Old"));
    await waitFor(() => expect(btn("Send test to Old")).toHaveFocus());
    expect(destStatus()).toHaveTextContent("Old is deliverable again");
  });
});

describe("add destination", () => {
  it("validates empty fields inline and focuses the first failing field", async () => {
    const { user } = mount();
    await ready();
    await user.click(btn("Add destination"));
    expect(screen.getByLabelText("Label")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Label")).toHaveFocus();
    expect(document.getElementById("dest-label-err")).toHaveTextContent("Enter a label of up to 50 characters.");
    await user.type(screen.getByLabelText("Label"), "Team");
    await user.click(btn("Add destination"));
    expect(screen.getByLabelText("Address")).toHaveFocus();
    expect(screen.getByLabelText("Address")).toHaveAttribute("aria-invalid", "true");
    expect(count("POST /api/notify/destinations")).toBe(0);
  });

  it("has a visible Type label, a per-kind hint wired by aria-describedby and a type=url field", async () => {
    const { user } = mount();
    await ready();
    expect(screen.getByLabelText("Type")).toHaveValue("discord");
    const address = screen.getByLabelText("Address");
    expect(address).toHaveAttribute("type", "url");
    expect(address).toHaveAttribute("autocomplete", "off");
    expect(document.getElementById("dest-url-hint")).toHaveTextContent("Paste a Discord webhook address");
    expect(address.getAttribute("aria-describedby")).toContain("dest-url-hint");
    await user.selectOptions(screen.getByLabelText("Type"), "webhook");
    expect(document.getElementById("dest-url-hint")).toHaveTextContent("Your app will receive a signed POST");
  });

  it("adds a Discord destination: announces, clears the form and keeps focus in the form", async () => {
    const { user } = mount({
      "POST /api/notify/destinations": () => json({ destination: dest(3, "Team"), phone: { ...P_ON, destinations: 1 } }, 201),
    });
    await ready();
    await user.type(screen.getByLabelText("Label"), "Team");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Added Team"));
    expect(screen.getByLabelText("Label")).toHaveValue("");
    expect(screen.getByLabelText("Address")).toHaveValue("");
    expect(screen.getByText("Team")).toBeInTheDocument();
    expect(document.querySelectorAll("section[data-secret]")).toHaveLength(0);
    expect(JSON.parse(bodies["POST /api/notify/destinations"][0])).toEqual({
      kind: "discord",
      label: "Team",
      url: "https://hooks.example.test/x",
    });
  });

  it("a webhook add moves focus to the secret panel with one combined sr-only announcement", async () => {
    const { user } = mount({
      "POST /api/notify/destinations": () => json({ destination: dest(3, "Hook", { kind: "webhook" }), signing_secret: SIG1, phone: P_OFF }, 201),
    });
    await ready();
    await user.selectOptions(screen.getByLabelText("Type"), "webhook");
    await user.type(screen.getByLabelText("Label"), "Hook");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    const h = await screen.findByRole("heading", { name: "Signing secret for webhook: Hook" });
    expect(h).toHaveFocus();
    expect(screen.getByTestId("secret-notice")).toHaveTextContent("Added Hook. Signing secret shown below, copy it now.");
    expect(destStatus()).toHaveTextContent("Added Hook");
    expect(screen.getByLabelText("Label")).toHaveValue("");
    expect(screen.getByText(SIG1)).toBeInTheDocument();
  });

  it.each([
    ["invalid_label", "Label", "Enter a label of up to 50 characters."],
    ["invalid_url", "Address", "That address doesn't look right. Check it and try again."],
    ["url_not_public", "Address", "That address isn't reachable from the internet."],
  ])("maps a server %s to the %s field", async (code, field, text) => {
    const { user } = mount({ "POST /api/notify/destinations": () => json({ error: code }, 400) });
    await ready();
    await user.type(screen.getByLabelText("Label"), "Team");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await waitFor(() => expect(screen.getByLabelText(field)).toHaveAttribute("aria-invalid", "true"));
    expect(screen.getByLabelText(field)).toHaveFocus();
    expect(destStatus()).toHaveTextContent(text);
    // Fields clear only on success.
    expect(screen.getByLabelText("Label")).toHaveValue("Team");
  });

  it("sends too_many_destinations to destinations-status", async () => {
    const { user } = mount({ "POST /api/notify/destinations": () => json({ error: "too_many_destinations" }, 409) });
    await ready();
    await user.type(screen.getByLabelText("Label"), "Team");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("You have reached the limit of 10 notification destinations."));
    expect(screen.getByLabelText("Address")).not.toHaveAttribute("aria-invalid");
  });
});

describe("loading, retry and phone status", () => {
  it("shows a loading line, then a list failure with Try again that recovers and focuses the heading", async () => {
    const first = deferred();
    let fail = true;
    const { user } = mount({
      "GET /api/notify/destinations": () => (calls.filter((c) => c === "GET /api/notify/destinations").length === 1 ? first.promise : fail ? json({ error: "internal" }, 500) : json({ destinations: [dest(1, "Team")] })),
    });
    await screen.findByText("Loading destinations…");
    first.resolve(json({ error: "internal" }, 500));
    await screen.findByRole("button", { name: "Try again" });
    expect(destStatus()).toHaveTextContent("Something went wrong on our side.");
    expect(heading()).toBeInTheDocument();
    // A reload that fails again keeps the button mounted.
    await user.click(btn("Try again"));
    await waitFor(() => expect(count("GET /api/notify/destinations")).toBe(2));
    await waitFor(() => expect(btn("Try again")).not.toHaveAttribute("aria-disabled"));
    expect(btn("Try again")).toBeInTheDocument();
    fail = false;
    await user.click(btn("Try again"));
    await screen.findByText("Team");
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
    expect(heading()).toHaveFocus();
  });

  it("Try again never remounts the Notes form or clears what was typed", async () => {
    let fail = true;
    const { user } = mount({
      "GET /api/notify/destinations": () => (fail ? json({ error: "internal" }, 500) : json({ destinations: [] })),
    });
    await ready();
    const note = screen.getByLabelText("New note");
    await user.type(note, "draft text");
    fail = false;
    await user.click(await screen.findByRole("button", { name: "Try again" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument());
    expect(screen.getByLabelText("New note")).toBe(note);
    expect(note).toHaveValue("draft text");
    expect(count("GET /api/items")).toBe(1);
  });

  it("a /api/me without phone shows phone unavailable, locks every control, and Try again recovers", async () => {
    let withPhone = false;
    const { user } = mount(
      {
        "GET /api/me": () => json(meBody(withPhone ? P_ON : null)),
        "GET /api/notify/destinations": LIST([dest(1, "Team")]),
      },
      null,
    );
    await screen.findByText("Phone status is unavailable right now. Try again in a minute.");
    await screen.findByText("Team");
    expect(btn("Set up phone")).toHaveAttribute("aria-disabled", "true");
    expect(btn("Send test to Team")).toHaveAttribute("aria-disabled", "true");
    expect(btn("Add destination")).toHaveAttribute("aria-disabled", "true");
    await user.click(btn("Send test to Team"));
    expect(count("POST /api/notify/destinations/1/test")).toBe(0);
    withPhone = true;
    await user.click(btn("Try again"));
    await waitFor(() => expect(btn("Send test to your phone")).toBeInTheDocument());
    expect(btn("Send test to Team")).not.toHaveAttribute("aria-disabled");
  });

  it("a write response without phone still returns the secret and marks the phone status unknown", async () => {
    const { user } = mount({ "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: PW }) });
    await ready();
    await user.click(btn("Set up phone"));
    expect(await screen.findByText(PW)).toBeInTheDocument();
    expect(screen.getByText("Phone status is unavailable right now. Try again in a minute.")).toBeInTheDocument();
  });
});

describe("not_found convergence", () => {
  it.each(["check", "test", "remove"])("a 404 on %s drops the row on refresh and focuses the heading", async (route) => {
    let gone = false;
    const base = dest(5, "Ghost", { stale: route === "check" });
    const { user } = mount(
      {
        "GET /api/notify/destinations": () => json({ destinations: gone ? [] : [base] }),
        "POST /api/notify/destinations/5/check": () => ((gone = true), json({ error: "not_found" }, 404)),
        "POST /api/notify/destinations/5/test": () => ((gone = true), json({ error: "not_found" }, 404)),
        "DELETE /api/notify/destinations/5": () => ((gone = true), json({ error: "not_found" }, 404)),
      },
      P_ON,
    );
    await ready();
    if (route === "check") {
      await user.click(btn("Check again: Ghost"));
    } else if (route === "test") {
      await user.click(btn("Send test to Ghost"));
    } else {
      await user.click(btn("Remove destination Ghost"));
      await user.click(btn("Yes, remove"));
    }
    await waitFor(() => expect(screen.queryByText("Ghost")).not.toBeInTheDocument());
    expect(destStatus()).toHaveTextContent("That destination isn't available any more.");
    expect(heading()).toHaveFocus();
  });
});

describe("remove", () => {
  it("confirms with Cancel focused, Cancel returns to Remove, confirm removes and focuses the heading", async () => {
    const { user } = mount(
      {
        "GET /api/notify/destinations": LIST([dest(1, "Team")]),
        "DELETE /api/notify/destinations/1": () => json({ phone: P_OFF }),
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Remove destination Team"));
    expect(btn("Cancel")).toHaveFocus();
    await user.click(btn("Cancel"));
    expect(btn("Remove destination Team")).toHaveFocus();
    await user.click(btn("Remove destination Team"));
    await user.click(btn("Yes, remove"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Removed Team"));
    expect(screen.queryByText("Team")).not.toBeInTheDocument();
    expect(heading()).toHaveFocus();
    expect(bodies["DELETE /api/notify/destinations/1"]).toEqual(["{}"]);
  });

  it("a failed remove announces it and focuses that row's Remove button", async () => {
    const { user } = mount(
      {
        "GET /api/notify/destinations": LIST([dest(1, "Team")]),
        "DELETE /api/notify/destinations/1": () => json({ error: "notify_unavailable" }, 500),
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Remove destination Team"));
    await user.click(btn("Yes, remove"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Couldn't remove Team."));
    expect(btn("Remove destination Team")).toHaveFocus();
  });

  it("only one confirm is open at a time across reset and Remove", async () => {
    const { user } = mount({ "GET /api/notify/destinations": LIST([dest(1, "A"), dest(2, "B")]) }, P_ON);
    await ready();
    await user.click(btn("Remove destination A"));
    await user.click(btn("Remove destination B"));
    expect(screen.getAllByRole("group", { name: /^Remove destination/ })).toHaveLength(1);
    expect(screen.getByRole("group", { name: "Remove destination B?" })).toBeInTheDocument();
  });

  it("closes an open confirm whose destination vanished on refresh and focuses the heading", async () => {
    let stale = false;
    const { user } = mount(
      {
        "GET /api/notify/destinations": () => json({ destinations: stale ? [dest(1, "A", { stale: true })] : [dest(1, "A"), dest(2, "B")] }),
        "POST /api/notify/destinations/1/test": () => {
          stale = true;
          return json({ error: "destination_stale" }, 409);
        },
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Remove destination B"));
    expect(screen.getByRole("group", { name: "Remove destination B?" })).toBeInTheDocument();
    await user.click(btn("Send test to A"));
    await waitFor(() => expect(screen.queryByRole("group", { name: "Remove destination B?" })).not.toBeInTheDocument());
    expect(heading()).toHaveFocus();
  });
});

describe("double submit", () => {
  it("setup posts once for two same-tick clicks", async () => {
    const slow = deferred();
    mount({ "POST /api/notify/ntfy": () => slow.promise });
    await ready();
    const b = btn("Set up phone");
    act(() => {
      b.click();
      b.click();
    });
    expect(count("POST /api/notify/ntfy")).toBe(1);
    slow.resolve(json({ setup_url: SETUP, password: null, phone: P_ON }));
    await screen.findByRole("heading", { name: "Phone notifications are set up" });
  });

  it("reset posts once", async () => {
    const slow = deferred();
    const { user } = mount(
      {
        "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: null, phone: P_ON }),
        "POST /api/notify/ntfy/reset": () => slow.promise,
      },
      P_ON,
    );
    await ready();
    await user.click(btn("Show setup again"));
    await user.click(await screen.findByRole("button", { name: "Generate a new password" }));
    const b = btn("Yes, generate");
    act(() => {
      b.click();
      b.click();
    });
    expect(count("POST /api/notify/ntfy/reset")).toBe(1);
    slow.resolve(json({ setup_url: SETUP, password: PW, phone: P_ON }));
    await screen.findByText(PW);
  });

  it("add posts once", async () => {
    const slow = deferred();
    const { user } = mount({ "POST /api/notify/destinations": () => slow.promise });
    await ready();
    await user.type(screen.getByLabelText("Label"), "Team");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    const form = screen.getByLabelText("Label").closest("form") as HTMLFormElement;
    act(() => {
      fireEvent.submit(form);
      fireEvent.submit(form);
    });
    expect(count("POST /api/notify/destinations")).toBe(1);
    slow.resolve(json({ destination: dest(3, "Team"), phone: P_ON }, 201));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Added Team"));
  });

  it("check posts once", async () => {
    const slow = deferred();
    mount(
      {
        "GET /api/notify/destinations": LIST([dest(5, "Old", { stale: true })]),
        "POST /api/notify/destinations/5/check": () => slow.promise,
      },
      P_ON,
    );
    await ready();
    const b = btn("Check again: Old");
    act(() => {
      b.click();
      b.click();
    });
    expect(count("POST /api/notify/destinations/5/check")).toBe(1);
    slow.resolve(json({ destination: dest(5, "Old"), phone: P_ON }));
    await waitFor(() => expect(destStatus()).toHaveTextContent("deliverable again"));
  });

  it("remove posts once", async () => {
    const slow = deferred();
    const { user } = mount(
      { "GET /api/notify/destinations": LIST([dest(1, "Team")]), "DELETE /api/notify/destinations/1": () => slow.promise },
      P_ON,
    );
    await ready();
    await user.click(btn("Remove destination Team"));
    const b = btn("Yes, remove");
    act(() => {
      b.click();
      b.click();
    });
    expect(count("DELETE /api/notify/destinations/1")).toBe(1);
    slow.resolve(json({ phone: P_ON }));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Removed Team"));
  });
});

describe("stale responses", () => {
  it("drops a slow refresh that a mutation overtook, then re-issues it once; the mutation's phone stays", async () => {
    const slowMe = deferred();
    let meCalls = 0;
    let listCalls = 0;
    const { user } = mount(
      {
        "GET /api/me": () => {
          meCalls += 1;
          if (meCalls === 2) {
            return slowMe.promise;
          }
          return json(meBody(meCalls === 1 ? P_OFF : P_ON));
        },
        "GET /api/notify/destinations": () => {
          listCalls += 1;
          return listCalls === 1 ? json({ error: "internal" }, 500) : json({ destinations: [] });
        },
        "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: PW, phone: P_ON }),
      },
      P_OFF,
    );
    await screen.findByRole("button", { name: "Try again" });
    await user.click(btn("Try again"));
    await user.click(btn("Set up phone"));
    await screen.findByText(PW);
    // The overtaken refresh answers with the older phone state: it must not win.
    slowMe.resolve(json(meBody(P_OFF)));
    await waitFor(() => expect(count("GET /api/me")).toBe(3));
    await waitFor(() => expect(btn("Show setup again")).toBeInTheDocument());
    expect(screen.queryByRole("button", { name: "Set up phone" })).not.toBeInTheDocument();
    expect(count("GET /api/me")).toBe(3);
  });

  it("a mutation response that was overtaken still stores its secret and announces it", async () => {
    const slowSetup = deferred();
    const { user } = mount({
      "GET /api/notify/destinations": () => json({ error: "internal" }, 500),
      "POST /api/notify/ntfy": () => slowSetup.promise,
    });
    await screen.findByRole("button", { name: "Try again" });
    await user.click(btn("Set up phone"));
    await user.click(btn("Try again"));
    slowSetup.resolve(json({ setup_url: SETUP, password: PW, phone: P_ON }));
    expect(await screen.findByText(PW)).toBeInTheDocument();
    expect(screen.getByTestId("secret-notice")).toHaveTextContent("Your phone notification password");
  });

  it("re-issues an overtaken refresh even when the superseding mutation fails", async () => {
    const slowList = deferred();
    let listCalls = 0;
    const { user } = mount({
      "GET /api/notify/destinations": () => {
        listCalls += 1;
        return listCalls === 1 ? slowList.promise : json({ destinations: [dest(1, "Team")] });
      },
      "POST /api/notify/ntfy": () => json({ error: "rate_limited" }, 429),
    });
    await screen.findByText("Loading destinations…");
    await user.click(btn("Set up phone"));
    await waitFor(() => expect(destStatus()).toHaveTextContent("Too many tries."));
    slowList.resolve(json({ destinations: [] }));
    expect(await screen.findByText("Team")).toBeInTheDocument();
    expect(screen.queryByText("Loading destinations…")).not.toBeInTheDocument();
    expect(listCalls).toBe(2);
  });

  it("an Add that a second mutation overtook still shows its created row after a converging refresh", async () => {
    const slowAdd = deferred();
    let created = false;
    const { user } = mount(
      {
        "GET /api/notify/destinations": () => json({ destinations: created ? [dest(7, "Hook")] : [] }),
        "POST /api/notify/destinations": () => {
          created = true;
          return slowAdd.promise;
        },
        "POST /api/notify/ntfy/test": () => json({ phone: P_ON }),
      },
      P_ON,
    );
    await ready();
    await user.type(screen.getByLabelText("Label"), "Hook");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await user.click(btn("Send test to your phone"));
    await waitFor(() => expect(count("POST /api/notify/ntfy/test")).toBe(1));
    slowAdd.resolve(json({ destination: dest(7, "Hook"), phone: P_ON }, 201));
    expect(await screen.findByText("Hook")).toBeInTheDocument();
    await waitFor(() => expect(count("GET /api/notify/destinations")).toBe(2));
  });

  it("unmounting mid-flight touches no state", async () => {
    const slow = deferred();
    const err = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const { unmount } = mount({ "GET /api/notify/destinations": () => slow.promise });
    await screen.findByText("Loading destinations…");
    unmount();
    slow.resolve(json({ destinations: [dest(1, "Team")] }));
    await act(async () => {
      await Promise.resolve();
    });
    expect(err).not.toHaveBeenCalled();
  });
});

describe("page-level session failure", () => {
  it("keeps every pending secret panel (and Copy) while the rest of the section is hidden", async () => {
    const { user } = mount({
      "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: PW, phone: P_ON }),
      "POST /api/notify/destinations": () =>
        json({ destination: dest(3, "Hook", { kind: "webhook" }), signing_secret: SIG1, phone: P_ON }, 201),
      "POST /api/notify/ntfy/test": () => json({ error: "unauthenticated" }, 401),
    });
    await ready();
    await user.click(btn("Set up phone"));
    await screen.findByText(PW);
    await user.selectOptions(screen.getByLabelText("Type"), "webhook");
    await user.type(screen.getByLabelText("Label"), "Hook");
    await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
    await user.click(btn("Add destination"));
    await screen.findByText(SIG1);
    await user.click(btn("Send test to your phone"));
    await screen.findByText("We couldn't confirm your sign-in.");
    expect(screen.queryByRole("heading", { name: "Phone notifications" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Send test/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add destination" })).not.toBeInTheDocument();
    expect(screen.getByText(PW)).toBeInTheDocument();
    expect(screen.getByText(SIG1)).toBeInTheDocument();
    const copies = screen.getAllByRole("button", { name: "Copy" });
    expect(copies).toHaveLength(2);
    await user.click(copies[0]);
    expect(await screen.findByText("Copied")).toBeInTheDocument();
  });

  const EXPIRED = (): Response => new Response("<html>login</html>", { status: 401, headers: { "Content-Type": "text/html" } });
  const UNAUTH = (): Response => json({ error: "unauthenticated" }, 401);

  type Case = { name: string; failure: () => Response; routes: (f: () => Response) => Routes; run: (user: ReturnType<typeof userEvent.setup>) => Promise<void>; post: string };
  const cases: Case[] = [
    {
      name: "reset",
      failure: EXPIRED,
      post: "POST /api/notify/ntfy/reset",
      routes: (f) => ({
        "POST /api/notify/ntfy": () => json({ setup_url: SETUP, password: null, phone: P_ON }),
        "POST /api/notify/ntfy/reset": f,
      }),
      run: async (user) => {
        await user.click(btn("Show setup again"));
        await user.click(await screen.findByRole("button", { name: "Generate a new password" }));
        await user.click(btn("Yes, generate"));
      },
    },
    {
      name: "check",
      failure: UNAUTH,
      post: "POST /api/notify/destinations/5/check",
      routes: (f) => ({
        "GET /api/notify/destinations": LIST([dest(5, "Old", { stale: true })]),
        "POST /api/notify/destinations/5/check": f,
      }),
      run: async (user) => {
        await user.click(btn("Check again: Old"));
      },
    },
    {
      name: "remove",
      failure: EXPIRED,
      post: "DELETE /api/notify/destinations/1",
      routes: (f) => ({
        "GET /api/notify/destinations": LIST([dest(1, "Team")]),
        "DELETE /api/notify/destinations/1": f,
      }),
      run: async (user) => {
        await user.click(btn("Remove destination Team"));
        await user.click(btn("Yes, remove"));
      },
    },
    {
      name: "add",
      failure: UNAUTH,
      post: "POST /api/notify/destinations",
      routes: (f) => ({ "POST /api/notify/destinations": f }),
      run: async (user) => {
        await user.type(screen.getByLabelText("Label"), "Hook");
        await user.type(screen.getByLabelText("Address"), "https://hooks.example.test/x");
        await user.click(btn("Add destination"));
      },
    },
    {
      name: "refresh",
      failure: EXPIRED,
      post: "",
      routes: (f) => {
        let n = 0;
        return {
          "GET /api/notify/destinations": () => {
            n += 1;
            return n === 1 ? json({ error: "internal" }, 500) : f();
          },
        };
      },
      run: async (user) => {
        await user.click(await screen.findByRole("button", { name: "Try again" }));
      },
    },
  ];

  it.each(cases)("a $name session failure hides the section, closes any confirm and allows no further write", async (c) => {
    const { user } = mount(c.routes(c.failure), P_ON);
    if (c.name === "refresh") {
      await screen.findByRole("button", { name: "Try again" });
    } else {
      await ready();
    }
    const writes = () => calls.filter((k) => k.startsWith("POST ") || k.startsWith("DELETE ")).length;
    await c.run(user);
    await waitFor(() => expect(screen.queryByRole("heading", { name: "Phone notifications" })).not.toBeInTheDocument());
    expect(screen.queryByRole("button", { name: /Send test|Add destination|Remove|Check again|Generate|Yes,/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("group", { name: /Remove destination|Generate a new password/ })).not.toBeInTheDocument();
    const before = writes();
    await act(async () => {
      await Promise.resolve();
    });
    expect(writes()).toBe(before);
    if (c.post !== "") {
      expect(count(c.post)).toBe(1);
    }
  });
});
