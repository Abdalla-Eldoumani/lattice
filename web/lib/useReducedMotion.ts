// A matchMedia hook reporting whether the user asked for reduced motion. It exists only to gate the
// minimap's one JS-driven node-add tween: every other animation in the app is CSS and is already
// collapsed by the global `@media (prefers-reduced-motion: reduce)` block in globals.css, which a JS
// animation is invisible to. useSyncExternalStore (not useEffect + useState) is the SSR-safe pattern —
// getServerSnapshot returns true so the server and the first client render agree on "no motion" (the
// accessibility-safe default), avoiding a hydration mismatch and a motion flash before the media query
// is read on the client.

import { useSyncExternalStore } from "react";

const QUERY = "(prefers-reduced-motion: reduce)";

function subscribe(callback: () => void): () => void {
  const media = window.matchMedia(QUERY);
  media.addEventListener("change", callback);
  return () => media.removeEventListener("change", callback);
}

function getSnapshot(): boolean {
  return window.matchMedia(QUERY).matches;
}

// On the server there is no matchMedia; default to reduced motion so SSR never emits the animated path
// and hydration stays stable until the client reads the real setting.
function getServerSnapshot(): boolean {
  return true;
}

export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
