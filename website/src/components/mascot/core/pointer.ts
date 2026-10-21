import { wake, type TickerEntry } from './ticker';
import type { Pt } from './types';

/**
 * One pointer listener for every mascot. Positions are stored, not broadcast: each following
 * mascot reads them on its own frame, with its rect cached until the layout changes.
 */
interface Follower {
  el: Element;
  entry: TickerEntry;
  rect: DOMRect | null;
  version: number;
}

const followers = new Set<Follower>();
let x = 0;
let y = 0;
let present = false;
let lastMove = 0;
let idleAfter = 4000;
let layoutVersion = 0;
let idleTimer = 0;
let installed = false;

const wakeAll = () => followers.forEach((f) => wake(f.entry));

function onMove(e: PointerEvent) {
  if (Math.abs(e.clientX - x) < 0.5 && Math.abs(e.clientY - y) < 0.5 && present) return;
  x = e.clientX;
  y = e.clientY;
  present = true;
  lastMove = performance.now();
  // A finger points briefly; a mouse keeps pointing until it rests.
  idleAfter = e.pointerType === 'touch' ? 1200 : 4000;
  window.clearTimeout(idleTimer);
  idleTimer = window.setTimeout(wakeAll, idleAfter + 20);
  wakeAll();
}

function onLeave() {
  present = false;
  wakeAll();
}

function onLayout() {
  layoutVersion++;
}

function install() {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  window.addEventListener('pointermove', onMove, { passive: true });
  window.addEventListener('pointerdown', onMove, { passive: true });
  document.documentElement.addEventListener('pointerleave', onLeave);
  window.addEventListener('blur', onLeave);
  window.addEventListener('scroll', onLayout, { passive: true, capture: true });
  window.addEventListener('resize', onLayout, { passive: true });
}

function uninstall() {
  if (!installed || followers.size) return;
  installed = false;
  window.removeEventListener('pointermove', onMove);
  window.removeEventListener('pointerdown', onMove);
  document.documentElement.removeEventListener('pointerleave', onLeave);
  window.removeEventListener('blur', onLeave);
  window.removeEventListener('scroll', onLayout, { capture: true });
  window.removeEventListener('resize', onLayout);
  window.clearTimeout(idleTimer);
}

export function follow(el: Element, entry: TickerEntry) {
  const f: Follower = { el, entry, rect: null, version: -1 };
  followers.add(f);
  install();
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(onLayout) : null;
  ro?.observe(el);
  return {
    gaze: () => gazeFor(f),
    stop: () => {
      ro?.disconnect();
      followers.delete(f);
      uninstall();
    },
  };
}

/** Direction to the pointer from the element's centre, saturating smoothly to length ≤ 1. */
function gazeFor(f: Follower): Pt | null {
  if (!present || performance.now() - lastMove > idleAfter) return null;
  if (!f.rect || f.version !== layoutVersion) {
    f.rect = f.el.getBoundingClientRect();
    f.version = layoutVersion;
  }
  const r = f.rect;
  const dx = x - (r.left + r.width / 2);
  const dy = y - (r.top + r.height / 2);
  const reach = Math.max(r.width, r.height, 80) * 1.1;
  const k = 1 / Math.hypot(Math.hypot(dx, dy), reach);
  return { x: dx * k, y: dy * k };
}

/** Lab hook: simulate the pointer without real events. */
export function simulatePointer(p: { x: number; y: number } | null) {
  if (p) onMove({ clientX: p.x, clientY: p.y, pointerType: 'mouse' } as PointerEvent);
  else onLeave();
}
