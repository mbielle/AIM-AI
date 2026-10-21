import type { Pt } from './types';

/** Two decimals is sub-pixel even at 1024 px for a 100-unit viewBox. */
export const fmt = (n: number) => {
  const r = Math.round(n * 100) / 100;
  return Object.is(r, -0) ? '0' : String(r);
};

/**
 * Closed Catmull-Rom spline through the points, as cubic Bézier path data. Tension below 1
 * tightens the curve, which keeps it from bulging past clamped corners.
 */
export function closedSpline(pts: Pt[], tension = 1): string {
  const n = pts.length;
  if (n < 3) return '';
  const k = tension / 6;
  let d = `M${fmt(pts[0].x)} ${fmt(pts[0].y)}`;
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n];
    const p1 = pts[i];
    const p2 = pts[(i + 1) % n];
    const p3 = pts[(i + 2) % n];
    d += `C${fmt(p1.x + (p2.x - p0.x) * k)} ${fmt(p1.y + (p2.y - p0.y) * k)} ${fmt(p2.x - (p3.x - p1.x) * k)} ${fmt(p2.y - (p3.y - p1.y) * k)} ${fmt(p2.x)} ${fmt(p2.y)}`;
  }
  return d + 'Z';
}

/** Exact ellipse as two arcs; `rot` in radians. */
export function ellipsePath(cx: number, cy: number, rx: number, ry: number, rot = 0): string {
  const c = Math.cos(rot);
  const s = Math.sin(rot);
  const x1 = cx - rx * c;
  const y1 = cy - rx * s;
  const x2 = cx + rx * c;
  const y2 = cy + rx * s;
  const deg = fmt((rot * 180) / Math.PI);
  return `M${fmt(x1)} ${fmt(y1)}A${fmt(rx)} ${fmt(ry)} ${deg} 1 0 ${fmt(x2)} ${fmt(y2)}A${fmt(rx)} ${fmt(ry)} ${deg} 1 0 ${fmt(x1)} ${fmt(y1)}Z`;
}

/** 2D affine transform [a, b, c, d, e, f] as in SVG `matrix()`. */
export type Affine = [number, number, number, number, number, number];

export const IDENTITY: Affine = [1, 0, 0, 1, 0, 0];

export function apply(m: Affine, p: Pt): Pt {
  return { x: m[0] * p.x + m[2] * p.y + m[4], y: m[1] * p.x + m[3] * p.y + m[5] };
}

/** m1 then m2 (m2 ∘ m1). */
export function then(m1: Affine, m2: Affine): Affine {
  return [
    m2[0] * m1[0] + m2[2] * m1[1],
    m2[1] * m1[0] + m2[3] * m1[1],
    m2[0] * m1[2] + m2[2] * m1[3],
    m2[1] * m1[2] + m2[3] * m1[3],
    m2[0] * m1[4] + m2[2] * m1[5] + m2[4],
    m2[1] * m1[4] + m2[3] * m1[5] + m2[5],
  ];
}

export const translate = (x: number, y: number): Affine => [1, 0, 0, 1, x, y];
export const rotate = (a: number): Affine => [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0];
export const scale = (sx: number, sy = sx): Affine => [sx, 0, 0, sy, 0, 0];

/** Rotation and scale about a pivot, then a translation. */
export function about(pivot: Pt, rot: number, sx: number, sy: number, dx = 0, dy = 0): Affine {
  let m = translate(-pivot.x, -pivot.y);
  m = then(m, scale(sx, sy));
  m = then(m, rotate(rot));
  return then(m, translate(pivot.x + dx, pivot.y + dy));
}

/** Distance from a point to the boundary of an ellipse, negative inside (approximate, fine for checks). */
export function insideEllipse(p: Pt, cx: number, cy: number, rx: number, ry: number, rot = 0) {
  const c = Math.cos(-rot);
  const s = Math.sin(-rot);
  const dx = p.x - cx;
  const dy = p.y - cy;
  const lx = dx * c - dy * s;
  const ly = dx * s + dy * c;
  return (lx * lx) / (rx * rx) + (ly * ly) / (ry * ry);
}

export function bounds(pts: Pt[]) {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const p of pts) {
    if (p.x < x0) x0 = p.x;
    if (p.y < y0) y0 = p.y;
    if (p.x > x1) x1 = p.x;
    if (p.y > y1) y1 = p.y;
  }
  return { x0, y0, x1, y1 };
}
