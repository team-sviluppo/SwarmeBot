/**
 * Whether mascots hold still instead of animating.
 *
 * The mascot engine draws every avatar on screen on a shared frame loop, and
 * that loop is the app's only always-on cost: SVG writes, compositing and a
 * commit per mascot per frame, plus the allocation churn behind them — in a
 * profile of the packaged app, a garbage collection triggered by that churn
 * landed inside a keystroke and held it for over a second. A still mascot
 * costs exactly one draw, at mount, and nothing after.
 *
 * Two things turn it on. The system's reduce-motion setting, which the
 * stylesheet already honours for CSS animations while the engine ignored it;
 * and a stored override, for measuring the difference the loop makes without
 * changing a system-wide preference:
 *
 *     localStorage.setItem("swarmebot.stillAvatars", "1")  // then reload
 */
import { useSyncExternalStore } from "react";

const REDUCE_MOTION = "(prefers-reduced-motion: reduce)";
export const STILL_AVATARS_KEY = "swarmebot.stillAvatars";

/** Read once: a preference that only takes effect on reload is easier to
 * reason about than one that can change under a half-drawn frame. */
const stored = (() => {
  try {
    return window.localStorage?.getItem(STILL_AVATARS_KEY) === "1";
  } catch {
    return false; // storage can be denied; a missing override is no override
  }
})();

function query(): MediaQueryList | null {
  return typeof window !== "undefined" && window.matchMedia ? window.matchMedia(REDUCE_MOTION) : null;
}

function subscribe(onChange: () => void): () => void {
  const media = query();
  media?.addEventListener("change", onChange);
  return () => media?.removeEventListener("change", onChange);
}

const snapshot = () => stored || query()?.matches === true;

/** True when mascots should render one resting frame and stop. */
export function useStillAvatars(): boolean {
  return useSyncExternalStore(subscribe, snapshot, () => false);
}
