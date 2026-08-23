import { describe, expect, it } from "vitest";

import { moveSection, nudgeSection, orderSections, renameInOrder } from "./section-order";

describe("orderSections", () => {
  it("follows the saved order and appends what it does not mention", () => {
    expect(orderSections(["Ops", "Design", "Research"], ["Research", "Ops"])).toEqual([
      "Research",
      "Ops",
      "Design",
    ]);
  });

  it("leaves a first run exactly as discovered", () => {
    expect(orderSections(["Ops", "Design"], [])).toEqual(["Ops", "Design"]);
  });

  it("ignores saved names that are not on screen right now", () => {
    // a search can filter every bot out of a section — it must not drag a
    // ghost row into the list
    expect(orderSections(["Ops"], ["Research", "Ops", "Design"])).toEqual(["Ops"]);
  });

  it("does not renumber the preference when a section is filtered away", () => {
    // Research is hidden by a search, then comes back: it has to return to its
    // saved slot, which only holds if the reader never rewrote the preference
    const saved = ["Research", "Ops"];
    expect(orderSections(["Ops"], saved)).toEqual(["Ops"]);
    expect(orderSections(["Ops", "Research"], saved)).toEqual(["Research", "Ops"]);
  });
});

describe("moveSection", () => {
  const order = ["A", "B", "C", "D"];

  it("lands after the target when dragged downward", () => {
    expect(moveSection(order, "A", "C")).toEqual(["B", "C", "A", "D"]);
  });

  it("lands before the target when dragged upward", () => {
    expect(moveSection(order, "D", "B")).toEqual(["A", "D", "B", "C"]);
  });

  it("moves to either end", () => {
    expect(moveSection(order, "A", "D")).toEqual(["B", "C", "D", "A"]);
    expect(moveSection(order, "D", "A")).toEqual(["D", "A", "B", "C"]);
  });

  it("is a no-op on itself or on a name it does not know", () => {
    expect(moveSection(order, "B", "B")).toEqual(order);
    expect(moveSection(order, "B", "Z")).toEqual(order);
    expect(moveSection(order, "Z", "B")).toEqual(order);
  });
});

describe("nudgeSection", () => {
  const order = ["A", "B", "C"];

  it("shifts one slot in each direction", () => {
    expect(nudgeSection(order, "C", -1)).toEqual(["A", "C", "B"]);
    expect(nudgeSection(order, "A", 1)).toEqual(["B", "A", "C"]);
  });

  it("stops at the ends instead of wrapping", () => {
    expect(nudgeSection(order, "A", -1)).toEqual(order);
    expect(nudgeSection(order, "C", 1)).toEqual(order);
  });
});

describe("renameInOrder", () => {
  it("keeps the slot the old name held", () => {
    expect(renameInOrder(["A", "B", "C"], "B", "Bravo")).toEqual(["A", "Bravo", "C"]);
  });

  it("leaves a preference that never knew the section alone", () => {
    expect(renameInOrder(["A", "B"], "Z", "Zulu")).toEqual(["A", "B"]);
  });

  it("collapses to one slot when a rename merges two sections", () => {
    // renaming B to A moves its bots into A — the surviving section keeps the
    // earlier slot rather than appearing twice
    expect(renameInOrder(["A", "B", "C"], "B", "A")).toEqual(["A", "C"]);
  });
});
