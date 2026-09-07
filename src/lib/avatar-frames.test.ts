import { describe, expect, it, vi } from "vitest";

import { createAvatarFrameBudget } from "./avatar-frames";

/** A claim plus the grants it was told about, which is what callers react to. */
function claimant(budget: ReturnType<typeof createAvatarFrameBudget>, priority = false) {
  const changes: boolean[] = [];
  const handle = budget.request(priority, (granted) => changes.push(granted));
  return { handle, changes };
}

describe("avatar frame budget", () => {
  it("grants up to the limit and refuses the rest", () => {
    const budget = createAvatarFrameBudget(2);
    const first = claimant(budget);
    const second = claimant(budget);
    const third = claimant(budget);

    expect([first, second, third].map((c) => c.handle.granted())).toEqual([true, true, false]);
    expect(budget.grantedCount()).toBe(2);
  });

  it("hands a released slot to the next claim in line", () => {
    const budget = createAvatarFrameBudget(1);
    const first = claimant(budget);
    const second = claimant(budget);
    expect(second.handle.granted()).toBe(false);

    first.handle.release();

    expect(second.handle.granted()).toBe(true);
    expect(second.changes).toEqual([true]);
    expect(budget.grantedCount()).toBe(1);
  });

  it("lets a priority claim take a slot from a decorative one", () => {
    const budget = createAvatarFrameBudget(1);
    const decorative = claimant(budget);
    expect(decorative.handle.granted()).toBe(true);

    // The selected row / a bot mid-turn arrives after a roster of idle mascots
    // has already filled the budget; its frames carry meaning, so it wins.
    const important = claimant(budget, true);

    expect(important.handle.granted()).toBe(true);
    expect(decorative.handle.granted()).toBe(false);
    expect(decorative.changes).toEqual([true, false]);
  });

  it("keeps the animating mascots animating as later claims arrive", () => {
    const budget = createAvatarFrameBudget(2);
    const first = claimant(budget);
    const second = claimant(budget);
    claimant(budget);
    claimant(budget);

    // Nothing re-shuffles the granted set: a list that scrolls must not make
    // the mascots already on screen flicker between still and animating.
    expect(first.changes).toEqual([true]);
    expect(second.changes).toEqual([true]);
  });

  it("tells a claim only when its answer actually changes", () => {
    const budget = createAvatarFrameBudget(2);
    const onChange = vi.fn();
    const handle = budget.request(false, onChange);
    // An unrelated mascot mounts and unmounts inside the budget. This claim
    // was granted throughout, so it must not be re-told — every needless
    // notification is a React state write and a re-render per mascot.
    const other = claimant(budget);
    other.handle.release();

    expect(handle.granted()).toBe(true);
    expect(onChange.mock.calls).toEqual([[true]]);
  });

  it("ignores a double release rather than freeing a slot twice", () => {
    const budget = createAvatarFrameBudget(1);
    const first = claimant(budget);
    const second = claimant(budget);

    first.handle.release();
    first.handle.release();

    expect(budget.grantedCount()).toBe(1);
    expect(second.changes).toEqual([true]);
  });
});
