import { lerp, smoothstep } from './motion';
import { closedSpline } from './shapes';
import type { Pt } from './types';

/**
 * Parametric "lens" eye: a superellipse clipped by an upper lid, a lower lid and an optional
 * happy ∩ band. One model covers the oval, the lidded eye, the closed ∪ line, the focused slit
 * and (with `rot`) the > < squeeze, so expressions morph by interpolating numbers instead of
 * swapping drawings.
 */
export interface Eye {
  x: number;
  y: number;
  /** Open size. */
  w: number;
  h: number;
  /** Superellipse exponent: 2 is an ellipse, higher is squarer. */
  n: number;
  /** Upper lid drop: 0 open, 1 shut (fraction of h). */
  lid: number;
  /** Lid slope across the eye, in fractions of h (+ lowers the lid towards +x). */
  lidTilt: number;
  /** Positive sags the lid edge at the centre (sleepy), negative arches it. */
  lidCurve: number;
  /** Lower lid raise (fraction of h). */
  low: number;
  /** Arches the lower lid upwards in the middle — smiling or squinting cheeks (fraction of h). */
  lowCurve?: number;
  /** 0…1 morph of the lower edge into a ∩ band that follows the top contour. */
  smile: number;
  /** Thickness of that band, in units. */
  smileT: number;
  rot: number;
  /** Thinnest the eye may get, in units. Ends stay round. */
  minT: number;
  /** Thickness of the line a fully shut eye becomes (∪ when `lidCurve` > 0). */
  shutT: number;
}

export const EYE_KEYS: (keyof Eye)[] = ['x', 'y', 'w', 'h', 'n', 'lid', 'lidTilt', 'lidCurve', 'low', 'lowCurve', 'smile', 'smileT', 'rot', 'minT', 'shutT'];

export function eyeLerp(a: Eye, b: Eye, t: number): Eye {
  const out = {} as Eye;
  for (const k of EYE_KEYS) out[k] = lerp(a[k] ?? 0, b[k] ?? 0, t);
  return out;
}

/** Round-ended thickness profile: 1 in the middle, a quarter circle over the last `r` of each side. */
function capProfile(u: number, r: number) {
  const au = Math.abs(u);
  if (r <= 0) return 1;
  if (au <= 1 - r) return 1;
  const d = (au - (1 - r)) / r;
  return Math.sqrt(Math.max(0, 1 - d * d));
}

/** Outline points of one eye, in the eye's parent coordinates. */
export function eyePoints(e: Eye, m = 14): Pt[] {
  const a = Math.max(e.w / 2, 0.01);
  const b = Math.max(e.h / 2, 0.01);
  const p = 2 / Math.max(e.n, 1.2);
  const top: Pt[] = [];
  const bottom: Pt[] = [];
  const r = Math.min(0.5, e.minT / (2 * a));
  const rShut = Math.min(0.5, e.shutT / (2 * a));
  for (let k = 0; k <= m; k++) {
    const th = (Math.PI * k) / m;
    const c = Math.cos(th);
    const s = Math.sin(th);
    const x = a * Math.sign(c) * Math.abs(c) ** p;
    const half = b * Math.abs(s) ** p;
    const u = x / a;
    let lo = -b + e.lid * 2 * b + e.lidTilt * u * b + e.lidCurve * (1 - u * u) * b;
    let hi = lerp(b - e.low * 2 * b - (e.lowCurve ?? 0) * (1 - u * u) * 2 * b, -half + e.smileT, e.smile);
    // Closing: both lids meet on a line a little below the centre, curved by `lidCurve`.
    const shut = smoothstep(0.55, 1, e.lid);
    if (shut > 0) {
      const line = b * 0.2 + e.lidCurve * b * (0.7 * (1 - u * u) - 0.35);
      const t = (e.shutT * capProfile(u, rShut)) / 2;
      lo = lerp(lo, line - t, shut);
      hi = lerp(hi, line + t, shut);
    }
    // A shut eye is its own line, no longer bounded by the open outline.
    let yT = lerp(Math.max(-half, lo), lo, shut);
    let yB = lerp(Math.min(half, hi), hi, shut);
    const tMin = e.minT * capProfile(u, r);
    if (yB - yT < tMin) {
      const mid = (yT + yB) / 2;
      yT = mid - tMin / 2;
      yB = mid + tMin / 2;
    }
    top.push({ x, y: yT });
    bottom.push({ x, y: yB });
  }
  const local = [...top, ...bottom.slice(1, m).reverse()];
  const c = Math.cos(e.rot);
  const s = Math.sin(e.rot);
  return local.map((q) => ({ x: e.x + q.x * c - q.y * s, y: e.y + q.x * s + q.y * c }));
}

export function eyePath(e: Eye) {
  return closedSpline(eyePoints(e), 0.92);
}
