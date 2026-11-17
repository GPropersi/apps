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
