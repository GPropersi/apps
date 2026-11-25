import { act, renderHook, waitFor } from "@testing-library/react";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Settings } from "./api";
import { useSettingsSaver } from "./useSettingsSaver";

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

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function onFailure(): boolean {
  return false;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("useSettingsSaver", () => {
  it("a later successful save does not revert a field whose own save failed", async () => {
    const answers = [reply({ error: "internal" }, 500), reply({ ...BASE, start_tab: "add" })];
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(answers.shift() ?? reply({}, 500))),
    );
    const { result } = renderHook(() => {
      const [s, setS] = useState<Settings | null>(BASE);
      return { s, saver: useSettingsSaver(setS, onFailure) };
    });

    act(() => result.current.saver.save({ list_view: "name" }));
    await waitFor(() => expect(result.current.saver.status).toBe("Couldn't save that. It is changed on this screen only."));
    expect(result.current.s?.list_view).toBe("name");

    act(() => result.current.saver.save({ start_tab: "add" }));
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.start_tab).toBe("add");
    expect(result.current.s?.list_view).toBe("name");
  });

  it("a successful save of the same field clears the failed override", async () => {
    const answers = [
      reply({ error: "internal" }, 500),
      reply({ ...BASE, list_view: "month" }),
      reply({ ...BASE, list_view: "month", start_tab: "view" }),
    ];
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(answers.shift() ?? reply({}, 500))),
    );
    const { result } = renderHook(() => {
      const [s, setS] = useState<Settings | null>(BASE);
      return { s, saver: useSettingsSaver(setS, onFailure) };
    });

    act(() => result.current.saver.save({ list_view: "name" }));
    await waitFor(() => expect(result.current.saver.status).toBe("Couldn't save that. It is changed on this screen only."));
    act(() => result.current.saver.save({ list_view: "month" }));
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.list_view).toBe("month");
    act(() => result.current.saver.save({ start_tab: "view" }));
    await waitFor(() => expect(answers.length).toBe(0));
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.list_view).toBe("month");
  });
});

const FAILED = "Couldn't save that. It is changed on this screen only.";

type Deferred = { promise: Promise<Response>; resolve: (r: Response) => void };

function deferred(): Deferred {
  let resolve: (r: Response) => void = () => undefined;
  const promise = new Promise<Response>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

// A fetch stub that answers each call from the next entry: a Response now, or a Deferred held until resolved.
function stubFetch(queue: (Response | Deferred)[]) {
  const f = vi.fn(() => {
    const next = queue.shift();
    if (next === undefined) {
      return Promise.resolve(reply({}, 500));
    }
    return next instanceof Response ? Promise.resolve(next) : next.promise;
  });
  vi.stubGlobal("fetch", f);
  return f;
}

function hook(fail: () => boolean = onFailure) {
  return renderHook(() => {
    const [s, setS] = useState<Settings | null>(BASE);
    return { s, saver: useSettingsSaver(setS, fail) };
  });
}

describe("useSettingsSaver adopt", () => {
  it("is a no-op for a key whose PATCH is in flight, and applies after it succeeds", async () => {
    const held = deferred();
    stubFetch([held, reply({ ...BASE, default_offsets: [28] })]);
    const { result } = hook();
    act(() => result.current.saver.save({ default_offsets: [28] }));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([28]);
    await act(async () => {
      held.resolve(reply({ ...BASE, default_offsets: [28] }));
    });
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
  });

  it("is a no-op for a key whose PATCH is queued", async () => {
    const held = deferred();
    const second = deferred();
    stubFetch([held, second]);
    const { result } = hook();
    act(() => result.current.saver.save({ default_offsets: [28] }));
    act(() => result.current.saver.save({ default_offsets: [28, 7] }));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([28, 7]);
    await act(async () => {
      held.resolve(reply({ ...BASE, default_offsets: [28] }));
    });
    await act(async () => {
      second.resolve(reply({ ...BASE, default_offsets: [28, 7] }));
    });
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.default_offsets).toEqual([28, 7]);
  });

  it("applies after a failed PATCH, clears the stale latest value, the failure line and the error flag", async () => {
    stubFetch([reply({ error: "internal" }, 500)]);
    const { result } = hook();
    act(() => result.current.saver.save({ default_offsets: [28] }));
    await waitFor(() => expect(result.current.saver.status).toBe(FAILED));
    expect(result.current.saver.latest("default_offsets")).toEqual([28]);
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
    expect(result.current.saver.latest("default_offsets")).toBeUndefined();
    expect(result.current.saver.status).toBe("");
    expect(result.current.saver.error).toBe(false);
  });

  it("leaves the failure line when another key is still overridden", async () => {
    stubFetch([reply({ error: "internal" }, 500), reply({ error: "internal" }, 500)]);
    const { result } = hook();
    act(() => result.current.saver.save({ default_offsets: [28] }));
    await waitFor(() => expect(result.current.saver.status).toBe(FAILED));
    act(() => result.current.saver.save({ list_view: "name" }));
    await waitFor(() => expect(result.current.saver.status).toBe(FAILED));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
    expect(result.current.saver.status).toBe(FAILED);
    expect(result.current.saver.error).toBe(true);
  });

  it("keeps the Saving status while another PATCH runs, which then ends Saved", async () => {
    const answers: (Response | Deferred)[] = [reply({ error: "internal" }, 500)];
    stubFetch(answers);
    const { result } = hook();
    act(() => result.current.saver.save({ default_offsets: [28] }));
    await waitFor(() => expect(result.current.saver.status).toBe(FAILED));
    const held = deferred();
    answers.push(held);
    act(() => result.current.saver.save({ list_view: "name" }));
    expect(result.current.saver.status).toBe("Saving…");
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.saver.status).toBe("Saving…");
    await act(async () => {
      held.resolve(reply({ ...BASE, list_view: "name", default_offsets: [28] }));
    });
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
    expect(result.current.s?.list_view).toBe("name");
    // overridden no longer pins default_offsets: a later response for another key carries the server's value through.
    answers.push(reply({ ...BASE, start_tab: "add", default_offsets: [99] }));
    act(() => result.current.saver.save({ start_tab: "add" }));
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.default_offsets).toEqual([99]);
  });

  it("is not overwritten by an older default_offsets in a response for another key", async () => {
    const held = deferred();
    stubFetch([held]);
    const { result } = hook();
    act(() => result.current.saver.save({ list_view: "name" }));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    await act(async () => {
      held.resolve(reply({ ...BASE, list_view: "name" }));
    });
    await waitFor(() => expect(result.current.saver.status).toBe("Saved."));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
    expect(result.current.s?.list_view).toBe("name");
  });

  it.each([
    ["ok", () => reply({ ...BASE, default_offsets: [28] }), onFailure],
    ["failed", () => reply({ error: "internal" }, 500), onFailure],
    ["session-lost", () => reply({ error: "internal" }, 500), () => true],
  ])("clears the in-flight state after a %s PATCH", async (_name, answer, fail) => {
    stubFetch([answer()]);
    const { result } = hook(fail);
    act(() => result.current.saver.save({ default_offsets: [28] }));
    await waitFor(() => expect(result.current.saver.status).not.toBe("Saving…"));
    act(() => result.current.saver.adopt({ default_offsets: [14, 1] }));
    expect(result.current.s?.default_offsets).toEqual([14, 1]);
  });
});
