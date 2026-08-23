// The order sidebar sections appear in.
//
// A section is not an entity — it is a label carried by each bot, so the set
// of sections is whatever the current bots (and the current search filter)
// happen to spell out. That makes a saved order a *preference over* a derived
// list, never the list itself: it can name sections that no longer exist, and
// it can be missing ones that just appeared. Both are normal, and orderSections
// is what reconciles them on every render.

/** Saved preference first, then whatever it does not mention.
 *
 * Unknown names are appended in the order they were discovered rather than
 * sorted: a section the user has never dragged should sit where it always sat.
 * Names in the preference that are absent from `present` are dropped for this
 * render but deliberately NOT forgotten — a section can vanish because a search
 * filtered its bots out, and forgetting it would silently reset a placement the
 * user chose. Pruning belongs to the writer, if ever, not to the reader. */
export function orderSections(present: readonly string[], saved: readonly string[]): string[] {
  const seen = new Set(present);
  const known = saved.filter((name) => seen.has(name));
  const placed = new Set(known);
  return [...known, ...present.filter((name) => !placed.has(name))];
}

/** Drop `dragged` onto `target`, taking its place.
 *
 * Dragging downward lands *after* the target and upward lands *before* it,
 * which is what makes a drag feel like it followed the pointer: the target is
 * the row the cursor is over, and the dragged section has to end up on the side
 * the cursor came from. */
export function moveSection(order: readonly string[], dragged: string, target: string): string[] {
  const from = order.indexOf(dragged);
  const to = order.indexOf(target);
  if (from < 0 || to < 0 || from === to) return [...order];
  const next = order.filter((name) => name !== dragged);
  const at = next.indexOf(target);
  next.splice(from < to ? at + 1 : at, 0, dragged);
  return next;
}

/** Shift `name` one slot, for the keyboard path — a drag nobody can perform
 * with a keyboard is a feature half the users do not have. */
export function nudgeSection(order: readonly string[], name: string, delta: -1 | 1): string[] {
  const from = order.indexOf(name);
  const to = from + delta;
  if (from < 0 || to < 0 || to >= order.length) return [...order];
  return moveSection(order, name, order[to]!);
}

/** Carry a placement across a rename, so a renamed section stays where it is
 * instead of reappearing at the bottom as if it were new. */
export function renameInOrder(saved: readonly string[], from: string, to: string): string[] {
  if (!saved.includes(from)) return [...saved];
  // a rename onto an existing name merges the two sections, so the survivor
  // keeps the earlier slot and the duplicate goes
  const renamed = saved.map((name) => (name === from ? to : name));
  return renamed.filter((name, i) => renamed.indexOf(name) === i);
}
