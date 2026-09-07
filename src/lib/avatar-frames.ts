/**
 * Which mascots are allowed to animate.
 *
 * The engine already shares one requestAnimationFrame across every mascot on
 * screen (see CursorAvatar's pump), but each animating mascot still costs SVG
 * writes, compositing and a commit on every frame that runs — and that was the
 * app's steadiest background cost, enough that a garbage collection triggered
 * by the churn landed inside a keystroke. The blunt fix was to freeze almost
 * everything: the sidebar animated only the selected row, so a roster of bots
 * sat there as still as a screenshot.
 *
 * Two gates replace that, and together they bound the cost without freezing
 * what you are looking at:
 *
 *   1. Visibility — a mascot scrolled out of the list is not worth a frame,
 *      and there is nobody to notice it stopped.
 *   2. A budget — a long visible list (or several panels at once) still has to
 *      stay bounded, so only the first LIMIT claimants animate.
 *
 * Priority is the escape hatch for the frames that carry meaning rather than
 * life: the selected row, a bot mid-turn, a one-shot motion beat playing. Those
 * claim a slot ahead of the merely-decorative ones, so a budget that is full of
 * idle roster mascots still yields to the bot that is actually working.
 */
import { useEffect, useState } from "react";

/**
 * How many mascots may animate at once.
 *
 * Their motion is slow by design and the pump runs at 30fps, so this is a
 * ceiling on simultaneous SVG churn rather than a frame-rate dial. A dozen
 * covers a full screen of sidebar rows plus an open panel's worth; beyond that
 * the extra mascots are off the edge of attention anyway.
 */
export const ANIMATED_AVATAR_LIMIT = 12;

export interface AvatarFrameHandle {
  granted: () => boolean;
  release: () => void;
}

export interface AvatarFrameBudget {
  request: (priority: boolean, onChange: (granted: boolean) => void) => AvatarFrameHandle;
  /** Granted slots right now — the property the tests assert on. */
  grantedCount: () => number;
}

/**
 * The allocator, as a factory so its behaviour can be tested without a DOM or
 * a React tree. Claims are kept in registration order; each recompute grants
 * priority claims first, then the rest, up to the limit, and tells only the
 * claims whose answer actually changed.
 */
export function createAvatarFrameBudget(limit: number): AvatarFrameBudget {
  interface Claim {
    priority: boolean;
    granted: boolean;
    onChange: (granted: boolean) => void;
  }

  // A Set iterates in insertion order, which is exactly the tie-break we want:
  // among equally-decorative mascots, the ones already animating keep their
  // slots instead of the set churning as a list scrolls.
  const claims = new Set<Claim>();

  const recompute = () => {
    let taken = 0;
    const decide = (claim: Claim) => {
      const granted = taken < limit;
      if (granted) taken++;
      if (claim.granted === granted) return;
      claim.granted = granted;
      claim.onChange(granted);
    };
    for (const claim of claims) if (claim.priority) decide(claim);
    for (const claim of claims) if (!claim.priority) decide(claim);
  };

  return {
    request(priority, onChange) {
      const claim: Claim = { priority, granted: false, onChange };
      claims.add(claim);
      recompute();
      return {
        granted: () => claim.granted,
        release() {
          if (!claims.delete(claim)) return;
          recompute();
        },
      };
    },
    grantedCount() {
      let granted = 0;
      for (const claim of claims) if (claim.granted) granted++;
      return granted;
    },
  };
}

const budget = createAvatarFrameBudget(ANIMATED_AVATAR_LIMIT);

/**
 * Claim an animation slot while `wanted`. Returns whether this mascot may
 * animate; false means it holds its resting face, which is what a mascot does
 * anyway when it is off-screen or beyond the budget.
 */
export function useAvatarFrameSlot(wanted: boolean, priority: boolean): boolean {
  const [granted, setGranted] = useState(false);

  useEffect(() => {
    if (!wanted) {
      setGranted(false);
      return;
    }
    const handle = budget.request(priority, setGranted);
    // The claim may already have been answered synchronously inside request().
    setGranted(handle.granted());
    return () => handle.release();
    // Re-claiming on a priority change costs this mascot its place in the
    // insertion order, which only decides ties between decorative claims —
    // and a claim that just became a priority one is no longer in that pool.
  }, [wanted, priority]);

  return wanted && granted;
}

/* -------------------------------------------------------------- visibility */

/**
 * One IntersectionObserver for every mascot rather than one each: a sidebar is
 * an observer per row otherwise, and they all report to the same place.
 *
 * The margin starts a row animating just before it scrolls into view, so it is
 * already alive by the time it is legible instead of visibly waking up.
 */
const VIEWPORT_MARGIN = "64px";

type VisibilityListener = (visible: boolean) => void;

const watched = new Map<Element, VisibilityListener>();
let observer: IntersectionObserver | null = null;

function ensureObserver(): IntersectionObserver | null {
  // Read off globalThis rather than testing the bare name: this is a feature
  // check for an embedder that may not have the API at all, and a server
  // render that has no DOM of any kind.
  const Observer = globalThis.IntersectionObserver;
  if (!Observer) return null;
  observer ??= new Observer(
    (entries) => {
      for (const entry of entries) watched.get(entry.target)?.(entry.isIntersecting);
    },
    { rootMargin: VIEWPORT_MARGIN },
  );
  return observer;
}

function watch(element: Element, listener: VisibilityListener): () => void {
  const active = ensureObserver();
  if (!active) return () => {};
  watched.set(element, listener);
  active.observe(element);
  return () => {
    watched.delete(element);
    active.unobserve(element);
  };
}

/**
 * Whether `ref`'s element is near the viewport. Without IntersectionObserver —
 * an older embedder, or a server render — it reports visible: a mascot that
 * animates when it did not have to is a cost, but one that never animates
 * because we could not measure it is a bug.
 */
export function useNearViewport(ref: { current: Element | null }, enabled: boolean): boolean {
  const [visible, setVisible] = useState(true);

  // ref.current is read here and not during render: React attaches refs after
  // the render body runs, so on the first pass the render body still sees null
  // and a mascot observed from there would never be observed at all.
  useEffect(() => {
    if (!enabled) return;
    const target = ref.current;
    if (!target) return;
    return watch(target, setVisible);
  }, [enabled, ref]);

  return enabled ? visible : false;
}
