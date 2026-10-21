import type { MascotModel } from './types';

/**
 * One shared frame loop for every mounted mascot.
 *
 * - A mascot at rest is parked and woken by a timer for its next event, so a page of idle
 *   mascots costs no frames.
 * - Mascots scrolled out of view are skipped until they come back.
 * - Everything stops while the tab is hidden; on return the clock resumes where it was
 *   instead of replaying the missed time.
 */
export interface TickerEntry {
  model: MascotModel;
  render: () => void;
  /** Called before the model ticks (pointer → gaze). */
  before?: () => void;
  timeScale: number;
  visible: boolean;
  parkedAt: number | null;
  timer: number | null;
}

const entries = new Set<TickerEntry>();
let raf = 0;
let last = 0;
const now = () => performance.now();

// Measurements for the lab's performance panel.
const samples: number[] = [];
let activeLast = 0;
let frames = 0;

function park(e: TickerEntry) {
  if (e.parkedAt !== null) return;
  e.parkedAt = now();
  if (!e.visible) return;
  const wait = e.model.wakeIn();
  if (Number.isFinite(wait)) e.timer = window.setTimeout(() => wake(e), wait * 1000 / e.timeScale + 8);
}

/**
 * Bring a parked model's clock up to the present without waking it. Call it BEFORE changing the
 * model (state, reaction, activity…): otherwise the change would be stamped with the time the model
 * was parked and the catch-up would then fast-forward through it.
 */
export function catchUp(e: TickerEntry) {
  if (!entries.has(e) || e.parkedAt === null || !e.visible) return;
  const t = now();
  e.model.skip(((t - e.parkedAt) / 1000) * e.timeScale);
  e.parkedAt = t;
}

export function wake(e: TickerEntry) {
  if (!entries.has(e)) return;
  if (e.timer !== null) window.clearTimeout(e.timer);
  e.timer = null;
  if (e.parkedAt !== null) {
    if (e.visible) e.model.skip(((now() - e.parkedAt) / 1000) * e.timeScale);
    e.parkedAt = null;
  }
  start();
}

function frame(ts: number) {
  const t0 = now();
  const dt = Math.min(0.05, Math.max(0, (ts - last) / 1000));
  last = ts;
  let active = 0;
  entries.forEach((e) => {
    if (e.parkedAt !== null) return;
    if (!e.visible) return park(e);
    e.before?.();
    e.model.tick(dt * e.timeScale);
    e.render();
    if (e.model.isSettled()) park(e);
    else active++;
  });
  frames++;
  activeLast = active;
  samples.push(now() - t0);
  if (samples.length > 240) samples.shift();
  raf = active > 0 ? requestAnimationFrame(frame) : 0;
}

function start() {
  if (raf || (typeof document !== 'undefined' && document.hidden)) return;
  last = now();
  raf = requestAnimationFrame(frame);
}

if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      // Freeze parked clocks too, so nothing "happened" while hidden.
      entries.forEach((e) => {
        if (e.timer !== null) window.clearTimeout(e.timer);
        e.timer = null;
        e.parkedAt = null;
      });
    } else {
      entries.forEach((e) => (e.parkedAt = null));
      start();
    }
  });
}

export function register(e: TickerEntry) {
  entries.add(e);
  e.render();
  start();
  return () => {
    if (e.timer !== null) window.clearTimeout(e.timer);
    entries.delete(e);
  };
}

export function setVisible(e: TickerEntry, visible: boolean) {
  if (e.visible === visible) return;
  e.visible = visible;
  if (visible) {
    // Resume from where it stopped; time spent off screen is not replayed.
    e.parkedAt = null;
    start();
  }
}

export function tickerStats() {
  const sorted = [...samples].sort((a, b) => a - b);
  const avg = sorted.length ? sorted.reduce((s, v) => s + v, 0) / sorted.length : 0;
  const p95 = sorted.length ? sorted[Math.floor(sorted.length * 0.95)] : 0;
  let parked = 0;
  entries.forEach((e) => (e.parkedAt !== null || !e.visible) && parked++);
  return { instances: entries.size, active: raf ? activeLast : 0, parked, running: raf !== 0, avgMs: avg, p95Ms: p95, frames };
}
