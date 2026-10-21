import { eyePoints, type Eye } from '../core/eye';
import { clamp, lerp, smoothstep } from '../core/motion';
import { about, apply, closedSpline, ellipsePath } from '../core/shapes';
import type { Frame, Pose, Pt } from '../core/types';

/*
 * The AIM companion: C's body (a pebble that stands up, leans and curls) carrying A's lidded
 * eyes. One filled body, two eyes, nothing else. Every expression is a set of numbers, so any
 * pose can blend into any other.
 */

export type CompanionVariant = 'mark' | 'companion';

export const GROUND = 92;

export const VIEWBOX: Record<CompanionVariant, [number, number, number, number]> = {
  mark: [0, 7, 100, 100],
  companion: [-25, -40, 150, 150],
};

/** Every key a pose can hold. Missing keys are a bug, so poses always start from REST. */
export const REST: Pose = {
  // Body: position, spine length, lean and bend, squash, girth, seat, hop and face tilt.
  bx: 50, len: 10, lean: 0.09, bend: 0, sq: 0, rB: 40, rT: 35, flat: 0.62, face: 0.12, hop: 0, roll: 0,
  feet: 0, footL: 0, footR: 0,
  // Gaze, -1…1.
  gx: 0.3, gy: -0.1,
  // Eyes. `in` lowers the inner corner of the lid (+, focused) or the outer one (−, sad).
  lidL: 0.1, lidR: 0.18, inL: 0, inR: 0, curveL: -0.04, curveR: -0.04, lowL: 0, lowR: 0, cheekL: 0, cheekR: 0,
  smileL: 0, smileR: 0, scaleL: 1, scaleR: 1, rotL: 0, rotR: 0, ew: 1, eh: 1,
};

/** Keys that belong to the eyes (they move on faster springs). */
export const EYE_KEYS = new Set([
  'lidL', 'lidR', 'inL', 'inR', 'curveL', 'curveR', 'lowL', 'lowR', 'cheekL', 'cheekR', 'smileL', 'smileR', 'scaleL', 'scaleR', 'rotL', 'rotR', 'ew', 'eh',
]);
export const GAZE_KEYS = new Set(['gx', 'gy']);

const add = (a: Pt, b: Pt, k = 1): Pt => ({ x: a.x + b.x * k, y: a.y + b.y * k });
const unit = (p: Pt, fallback: Pt): Pt => {
  const l = Math.hypot(p.x, p.y);
  return l < 1e-4 ? fallback : { x: p.x / l, y: p.y / l };
};

/**
 * Body outline in rest space (x right, y up): the convex hull of a base circle at the origin and
 * a top circle `len` above it, sampled evenly along the perimeter. The seat is flattened.
 */
function restOutline(pose: Pose, samples = 48): Pt[] {
  const L = Math.max(0, pose.len);
  const r1 = pose.rB;
  const r2 = pose.rT;
  const d = r1 - r2;
  const beta = L > Math.abs(d) + 1e-6 ? Math.asin(d / L) : d >= 0 ? Math.PI / 2 : -Math.PI / 2;
  const seg = Math.sqrt(Math.max(0, L * L - d * d));
  const arcTop = r2 * (Math.PI - 2 * beta);
  const arcBottom = r1 * (Math.PI + 2 * beta);
  const total = arcTop + arcBottom + 2 * seg;
  const at = (s: number): Pt => {
    if (s < arcTop) {
      const a = beta + s / r2;
      return { x: r2 * Math.cos(a), y: L + r2 * Math.sin(a) };
    }
    s -= arcTop;
    if (s < seg) {
      const a = Math.PI - beta;
      const k = s / seg;
      return { x: lerp(r2, r1, k) * Math.cos(a), y: lerp(L + r2 * Math.sin(a), r1 * Math.sin(a), k) };
    }
    s -= seg;
    if (s < arcBottom) {
      const a = Math.PI - beta + s / r1;
      return { x: r1 * Math.cos(a), y: r1 * Math.sin(a) };
    }
    s -= arcBottom;
    const k = Math.min(1, s / Math.max(seg, 1e-6));
    return { x: lerp(r1, r2, k) * Math.cos(beta), y: lerp(r1 * Math.sin(beta), L + r2 * Math.sin(beta), k) };
  };
  const pts: Pt[] = [];
  for (let i = 0; i < samples; i++) {
    const p = at((total * i) / samples);
    if (p.y < 0) p.y *= pose.flat;
    pts.push(p);
  }
  return pts;
}

export interface CompanionDrawOptions {
  /** Rendered width in CSS pixels, for optical sizing. */
  size: number;
  variant: CompanionVariant;
  /** Two small filled feet (large formats only). */
  feet?: boolean;
}

export function drawCompanion(pose: Pose, { size, variant, feet: feetOption = false }: CompanionDrawOptions): Frame {
  const vbW = VIEWBOX[variant][2];
  // Optical size: 0 at favicon sizes, 1 from ~64 px. Small renders get larger, simpler eyes.
  const o = smoothstep(20, 64, (size * 100) / vbW);
  const minT = Math.max(lerp(4.2, 2.6, o), (1.15 * vbW) / size);
  const feet = feetOption && variant === 'companion' ? clamp(pose.feet, 0, 1) : 0;
  const lift = feet * 7 + Math.max(0, pose.hop);

  // Posture: a bend deformer over the whole height. The seat stays flat and the body leans and
  // curves progressively towards the top, so nothing kinks whatever the length.
  const L = Math.max(0, pose.len);
  const yMin = -pose.rB * pose.flat;
  const H = Math.max(L + pose.rT, pose.rB) - yMin;
  const ground = GROUND - lift;
  const lean = H * pose.lean;
  const bend = clamp(pose.bend, -0.22 * H, 0.22 * H);
  const off = (t: number) => lean * t * t + bend * t * t * (3 - 2 * t);
  const dOff = (t: number) => 2 * lean * t + bend * 6 * t * (1 - t);
  const tan = (t: number): Pt => unit({ x: dOff(t), y: -H }, { x: 0, y: -1 });
  const place = (p: Pt): Pt => {
    const t = clamp((p.y - yMin) / H, 0, 1);
    const d = tan(t);
    return { x: pose.bx + off(t) - d.y * p.x, y: ground - t * H + d.x * p.x };
  };

  // Face: near the top, following the body there, plus its own tilt.
  const faceY = L + pose.rT * pose.face;
  const tf = tan(clamp((faceY - yMin) / H, 0, 1));
  const faceRot = Math.atan2(tf.x, -tf.y) + pose.roll;
  const ux = { x: Math.cos(faceRot), y: Math.sin(faceRot) };
  const uy = { x: -Math.sin(faceRot), y: Math.cos(faceRot) };
  const faceC = place({ x: 0, y: faceY });

  // A's eyes: tall ovals with a flat lid, scaled to the top of the body (a little larger on the
  // standing companion, whose body is taller).
  const k = (pose.rT / 35) * (variant === 'companion' ? 1.14 : 1);
  const w = lerp(15, 11.8, o) * k * pose.ew;
  const h = lerp(25, 22.5, o) * k * pose.eh;
  const gap = lerp(28.5, 25, o) * k;
  const lidScale = lerp(0.4, 1, o);
  const gx = clamp(pose.gx, -1, 1);
  const gy = clamp(pose.gy, -1, 1);
  const eyes: Eye[] = [-1, 1].map((side, i) => {
    const S = i === 0 ? 'L' : 'R';
    const s = pose[`scale${S}`];
    // Looking sideways slides the eyes across the face and narrows the far one.
    const far = Math.max(0, -side * gx);
    const lx = side * gap * 0.5 * (1 - 0.1 * Math.abs(gx)) + gx * 8 * k;
    const ly = gy * 5.5 * k;
    const c = add(add(faceC, ux, lx), uy, ly);
    const lid = clamp(pose[`lid${S}`], 0, 1);
    return {
      x: c.x,
      y: c.y,
      w: w * s * (1 - 0.24 * far),
      h: h * s,
      n: 2.25,
      // Small renders soften resting lids; a closing eye still closes fully.
      lid: lerp(lid * lidScale, lid, smoothstep(0.45, 0.95, lid)),
      lidTilt: side === -1 ? pose.inL * lidScale : -pose.inR * lidScale,
      lidCurve: pose[`curve${S}`],
      low: pose[`low${S}`],
      lowCurve: pose[`cheek${S}`],
      smile: clamp(pose[`smile${S}`], 0, 1),
      smileT: Math.max(minT, h * s * 0.42),
      rot: faceRot + side * -pose[`rot${S}`],
      minT,
      shutT: Math.max(minT, h * 0.19),
    };
  });

  // Squash about the ground contact so the body stays seated (or lands) on it.
  const m = about({ x: pose.bx, y: ground }, 0, 1 + pose.sq * 0.6, 1 - pose.sq);
  let fills = closedSpline(restOutline(pose).map((p) => apply(m, place(p))), 1);
  if (feet > 0.01) {
    const fx = pose.rB * 0.46;
    const fy = GROUND - 4.6 - Math.max(0, pose.hop);
    fills += ellipsePath(pose.bx - fx, fy - pose.footL, 10.5 * feet, 4.8 * feet);
    fills += ellipsePath(pose.bx + fx, fy - pose.footR, 10.5 * feet, 4.8 * feet);
  }
  return { fills, eyes: eyes.map((e) => closedSpline(eyePoints(e).map((p) => apply(m, p)), 0.92)).join('') };
}
