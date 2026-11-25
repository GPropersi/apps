import { fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import type { ComponentProps } from "react";
import { describe, expect, it, vi } from "vitest";
import { TimingPicker } from "./TimingPicker";

type Props = Partial<ComponentProps<typeof TimingPicker>>;

function Harness({ initial, onSubmit, ...rest }: Props & { initial: number[]; onSubmit?: () => void }) {
  const [value, setValue] = useState(initial);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit?.();
      }}
    >
      <TimingPicker
        idPrefix="t"
        legend="Timing"
        allowEmpty
        {...rest}
        value={value}
        onChange={(n) => {
          rest.onChange?.(n);
          setValue(n);
        }}
      />
    </form>
  );
}

function selectEl(): HTMLSelectElement {
  return screen.getByLabelText("Add weeks before");
}
function addBtn(): HTMLElement {
  return screen.getByRole("button", { name: "Add" });
}
function removeBtn(n: number): HTMLElement {
  return screen.getByRole("button", { name: `Remove ${n === 1 ? "1 week" : `${n} weeks`} before` });
}

describe("TimingPicker", () => {
  it("adds weeks in canonical order and removes them from the select options", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(<Harness initial={[1]} onChange={onChange} />);
    await user.selectOptions(selectEl(), "2");
    await user.click(addBtn());
    await user.selectOptions(selectEl(), "4");
    await user.click(addBtn());
    expect(onChange).toHaveBeenLastCalledWith([28, 14, 1]);
    const options = within(selectEl()).getAllByRole("option").map((o) => (o as HTMLOptionElement).value);
    expect(options).not.toContain("2");
    expect(options).not.toContain("4");
    expect(options[0]).toBe("");
    expect(selectEl()).toHaveValue("");
    expect(addBtn()).toBeDisabled();
  });

  it("enables Add only once a week is chosen and a double click adds one timing", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(<Harness initial={[0]} onChange={onChange} />);
    expect(addBtn()).toBeDisabled();
    await user.selectOptions(selectEl(), "3");
    expect(addBtn()).toBeEnabled();
    fireEvent.click(addBtn());
    fireEvent.click(addBtn());
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith([21, 0]);
  });

  it("removes a week, announces it, and moves focus to the next chip, else the previous, else the select", async () => {
    const user = userEvent.setup();
    render(<Harness initial={[28, 14, 7]} />);
    await user.click(removeBtn(2));
    expect(screen.getByRole("status")).toHaveTextContent("Removed 2 weeks before");
    expect(removeBtn(1)).toHaveFocus();
    await user.click(removeBtn(1));
    expect(removeBtn(4)).toHaveFocus();
    await user.click(removeBtn(4));
    expect(selectEl()).toHaveFocus();
  });

  it("announces an add and returns focus to the select", async () => {
    const user = userEvent.setup();
    render(<Harness initial={[1]} />);
    await user.selectOptions(selectEl(), "1");
    await user.click(addBtn());
    expect(screen.getByRole("status")).toHaveTextContent("Added 1 week before");
    expect(selectEl()).toHaveFocus();
  });

  it("refuses to empty the picker when allowEmpty is false", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(<Harness initial={[1]} allowEmpty={false} emptyMessage="Pick at least one reminder time." onChange={onChange} />);
    await user.click(screen.getByRole("checkbox", { name: "1 day before" }));
    expect(onChange).not.toHaveBeenCalled();
    expect(screen.getByRole("alert")).toHaveTextContent("Pick at least one reminder time.");
    expect(screen.getByRole("checkbox", { name: "1 day before" })).toBeChecked();
    await user.click(screen.getByRole("checkbox", { name: "On the day" }));
    expect(screen.getByRole("alert")).toHaveTextContent("");
  });

  it("refuses to remove the last week when allowEmpty is false", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(<Harness initial={[7]} allowEmpty={false} emptyMessage="Need one." onChange={onChange} />);
    await user.click(removeBtn(1));
    expect(onChange).not.toHaveBeenCalled();
    expect(screen.getByRole("alert")).toHaveTextContent("Need one.");
    expect(removeBtn(1)).toBeInTheDocument();
  });

  it("allows an empty picker otherwise", async () => {
    const onChange = vi.fn();
    const user = userEvent.setup();
    render(<Harness initial={[1]} onChange={onChange} />);
    await user.click(screen.getByRole("checkbox", { name: "1 day before" }));
    expect(onChange).toHaveBeenCalledWith([]);
  });

  it("shows a caller error with the err id, listed in aria-describedby, and ids the first checkbox", () => {
    render(<Harness initial={[0]} error="Server says no." describedBy="hint-x" idPrefix="ab" />);
    const alert = screen.getByRole("alert");
    expect(alert).toHaveTextContent("Server says no.");
    expect(alert).toHaveAttribute("id", "ab-err");
    const group = screen.getByRole("group", { name: "Timing" });
    expect(group.getAttribute("aria-describedby")).toBe("ab-err hint-x");
    expect(group).not.toHaveAttribute("aria-labelledby");
    expect(screen.getByRole("checkbox", { name: "On the day" })).toHaveAttribute("id", "ab-0");
  });

  it("names the group by legend, which wins over labelledBy, or by labelledBy alone", () => {
    const { unmount } = render(
      <div>
        <h2 id="h">Heading</h2>
        <Harness initial={[0]} labelledBy="h" />
      </div>,
    );
    expect(screen.getByRole("group", { name: "Timing" })).toBeInTheDocument();
    unmount();
    render(
      <div>
        <h2 id="h">Heading</h2>
        <Harness initial={[0]} legend={undefined} labelledBy="h" />
      </div>,
    );
    const group = screen.getByRole("group", { name: "Heading" });
    expect(group.querySelector("legend")).toBeNull();
  });

  it("clears a stale status when the value changes from outside, but not for an equal re-pass", async () => {
    const user = userEvent.setup();
    function Outer() {
      const [v, setV] = useState([7]);
      return (
        <>
          <button type="button" onClick={() => setV([7])}>
            outside
          </button>
          <button type="button" onClick={() => setV([14, 7])}>
            equalNewArray
          </button>
          <TimingPicker idPrefix="t" legend="T" allowEmpty value={v} onChange={(n) => setV(n)} />
        </>
      );
    }
    render(<Outer />);
    await user.selectOptions(selectEl(), "2");
    await user.click(addBtn());
    expect(screen.getByRole("status")).toHaveTextContent("Added 2 weeks before");
    await user.click(screen.getByRole("button", { name: "equalNewArray" }));
    expect(screen.getByRole("status")).toHaveTextContent("Added 2 weeks before");
    await user.click(screen.getByRole("button", { name: "outside" }));
    expect(screen.getByRole("status")).toHaveTextContent("");
  });

  it("keeps the status when the parent re-passes a new array of equal content after the picker's own change", async () => {
    const user = userEvent.setup();
    function Outer() {
      const [v, setV] = useState([7]);
      return <TimingPicker idPrefix="t" legend="T" allowEmpty value={v} onChange={(n) => setV([...n])} />;
    }
    render(<Outer />);
    await user.selectOptions(selectEl(), "2");
    await user.click(addBtn());
    expect(screen.getByRole("status")).toHaveTextContent("Added 2 weeks before");
  });

  it("disables the adder when all 52 weeks are chosen and focuses the last chip", async () => {
    const user = userEvent.setup();
    const all = Array.from({ length: 51 }, (_, i) => (52 - i) * 7).filter((v) => v !== 7);
    render(<Harness initial={all} />);
    await user.selectOptions(selectEl(), "1");
    await user.click(addBtn());
    expect(selectEl()).toBeDisabled();
    expect(addBtn()).toBeDisabled();
    expect(removeBtn(1)).toHaveFocus();
  });

  it("disables every control when disabled", () => {
    render(<Harness initial={[7, 0]} disabled />);
    expect(screen.getByRole("checkbox", { name: "On the day" })).toBeDisabled();
    expect(selectEl()).toBeDisabled();
    expect(removeBtn(1)).toBeDisabled();
  });

  it("Enter on the select adds the week, on the placeholder adds nothing, and never submits", () => {
    const onChange = vi.fn();
    render(<Harness initial={[0]} onChange={onChange} />);
    const sel = selectEl();
    expect(fireEvent.keyDown(sel, { key: "Enter" })).toBe(false);
    expect(onChange).not.toHaveBeenCalled();
    fireEvent.change(sel, { target: { value: "5" } });
    expect(fireEvent.keyDown(sel, { key: "Enter" })).toBe(false);
    expect(onChange).toHaveBeenCalledWith([35, 0]);
  });

  it("Enter on the checkboxes does nothing and is prevented", () => {
    const onChange = vi.fn();
    render(<Harness initial={[0]} onChange={onChange} />);
    expect(fireEvent.keyDown(screen.getByRole("checkbox", { name: "On the day" }), { key: "Enter" })).toBe(false);
    expect(fireEvent.keyDown(screen.getByRole("checkbox", { name: "1 day before" }), { key: "Enter" })).toBe(false);
    expect(onChange).not.toHaveBeenCalled();
  });

  it("does not prevent Enter on the Add and chip-remove buttons", () => {
    render(<Harness initial={[7]} />);
    expect(fireEvent.keyDown(addBtn(), { key: "Enter" })).toBe(true);
    expect(fireEvent.keyDown(removeBtn(1), { key: "Enter" })).toBe(true);
  });
});
