/**
 * Hero cursor trail — pure simulation, no DOM.
 *
 * An intensity field lives on an invisible monospace grid. Moving the pointer deposits intensity
 * around its path; every cell also stores its OWN velocity, inherited at deposit time, and a
 * sub-cell offset. Each step advances that offset along the cell's velocity and hops the cell's
 * whole content (intensity, velocity, glyph) to the neighbouring cell once it crosses a border —
 * transport without numerical smearing, so the shape stays crisp while it drifts. Velocity decays
 * (inertia), a faint low-frequency drift and light diffusion keep the shape evolving, and the
 * intensity decays until the cell drops out. Everything is a function of elapsed time. A new
 * pointer direction only affects new deposits — the old wake never rotates.
 */
import type { TrailConfig } from './trailConfig';

const LN2 = Math.LN2;

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Small deterministic PRNG so tests are repeatable. */
export function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const hash2 = (x: number, y: number, s: number) => {
  let h = (x * 374761393 + y * 668265263 + s * 2246822519) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
};

export class CodeTrail {
  cfg: TrailConfig;
  cols = 0;
  rows = 0;
  width = 0;
  height = 0;
  t = 0;
  private I = new Float32Array(0);
  private VX = new Float32Array(0);
  private VY = new Float32Array(0);
  private nI = new Float32Array(0);
  private nVX = new Float32Array(0);
  private nVY = new Float32Array(0);
  private OX = new Float32Array(0);
  private OY = new Float32Array(0);
  private nOX = new Float32Array(0);
  private nOY = new Float32Array(0);
  private nMax = new Float32Array(0);
  private nSeed = new Uint8Array(0);
  private seed = new Uint8Array(0);
  private mask = new Float32Array(0);
  private isActive = new Uint8Array(0);
  private nextMark = new Uint8Array(0);
  private active = new Int32Array(0);
  private nextList = new Int32Array(0);
  private count = 0;
  private nextCount = 0;
  private last: { x: number; y: number; t: number } | null = null;
  private rng: () => number;

  constructor(width: number, height: number, cfg: TrailConfig, seed = 1) {
    this.cfg = cfg;
    this.rng = mulberry32(seed);
    this.resize(width, height);
  }

  resize(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.cols = Math.max(1, Math.ceil(width / this.cfg.cellW));
    this.rows = Math.max(1, Math.ceil(height / this.cfg.cellH));
    const n = this.cols * this.rows;
    this.I = new Float32Array(n);
    this.VX = new Float32Array(n);
    this.VY = new Float32Array(n);
    this.nI = new Float32Array(n);
    this.nVX = new Float32Array(n);
    this.nVY = new Float32Array(n);
    this.OX = new Float32Array(n);
    this.OY = new Float32Array(n);
    this.nOX = new Float32Array(n);
    this.nOY = new Float32Array(n);
    this.nMax = new Float32Array(n);
    this.nSeed = new Uint8Array(n);
    this.seed = new Uint8Array(n);
    this.mask = new Float32Array(n).fill(1);
    this.isActive = new Uint8Array(n);
    this.nextMark = new Uint8Array(n);
    this.active = new Int32Array(n);
    this.nextList = new Int32Array(n);
    this.count = 0;
    this.last = null;
  }

  /** Dim the trail over these rects (headline, buttons) with a soft edge. */
  setMask(rects: Rect[]) {
    const { cellW, cellH, textDim, textFeather } = this.cfg;
    for (let cy = 0; cy < this.rows; cy++) {
      for (let cx = 0; cx < this.cols; cx++) {
        const px = (cx + 0.5) * cellW;
        const py = (cy + 0.5) * cellH;
        let d = Infinity;
        for (const r of rects) {
          const dx = Math.max(r.x - px, 0, px - (r.x + r.w));
          const dy = Math.max(r.y - py, 0, py - (r.y + r.h));
          d = Math.min(d, Math.hypot(dx, dy));
        }
        const u = Math.min(1, d / Math.max(1, textFeather));
        const s = u * u * (3 - 2 * u);
        this.mask[cy * this.cols + cx] = textDim + (1 - textDim) * s;
      }
    }
  }

  clear() {
    for (let i = 0; i < this.count; i++) {
      const idx = this.active[i];
      this.I[idx] = 0;
      this.VX[idx] = 0;
      this.VY[idx] = 0;
      this.OX[idx] = 0;
      this.OY[idx] = 0;
      this.isActive[idx] = 0;
    }
    this.count = 0;
  }

  /** Forget the previous pointer position (leave/enter, hidden tab): no line is drawn across. */
  resetPointer() {
    this.last = null;
  }

  activeCount() {
    return this.count;
  }

  private activate(idx: number) {
    if (this.isActive[idx]) return true;
    if (this.count >= this.cfg.maxCells) return false;
    this.isActive[idx] = 1;
    this.active[this.count++] = idx;
    this.seed[idx] = (this.rng() * 256) | 0;
    return true;
  }

  private depositDisc(px: number, py: number, amount: number, vx: number, vy: number, salt: number) {
    const { cellW, cellH, radius, density, runLength } = this.cfg;
    const cx0 = Math.max(0, Math.floor((px - radius) / cellW));
    const cx1 = Math.min(this.cols - 1, Math.floor((px + radius) / cellW));
    const cy0 = Math.max(0, Math.floor((py - radius) / cellH));
    const cy1 = Math.min(this.rows - 1, Math.floor((py + radius) / cellH));
    for (let cy = cy0; cy <= cy1; cy++) {
      for (let cx = cx0; cx <= cx1; cx++) {
        const d = Math.hypot((cx + 0.5) * cellW - px, (cy + 0.5) * cellH - py);
        if (d > radius) continue;
        // Light whole horizontal runs (offset per row) so glyphs read as rows, not scattered dots.
        const run = Math.floor((cx + ((hash2(0, cy, 11) * runLength) | 0)) / Math.max(1, runLength));
        if (hash2(run, cy, salt) > density) continue;
        const f = (1 - d / radius) ** 2;
        const add = amount * f * 1.5;
        const idx = cy * this.cols + cx;
        if (!this.activate(idx)) continue;
        const old = this.I[idx];
        const sum = old + add;
        this.VX[idx] = (this.VX[idx] * old + vx * add) / sum;
        this.VY[idx] = (this.VY[idx] * old + vy * add) / sum;
        this.I[idx] = Math.min(1.4, sum);
      }
    }
  }

  /** Feed a pointer position (CSS px relative to the canvas) with its timestamp in ms. */
  pointer(x: number, y: number, timeMs: number) {
    const c = this.cfg;
    const last = this.last;
    this.last = { x, y, t: timeMs };
    if (!last) return;
    const dtMs = timeMs - last.t;
    const dist = Math.hypot(x - last.x, y - last.y);
    if (dtMs > c.resumeGapMs || dist > c.resumeGapPx) return; // new stroke, nothing drawn across
    if (dist < 0.5) return;
    const dt = Math.max(1, dtMs) / 1000;
    const speed = Math.min(c.maxPointerSpeed, dist / dt);
    const gain = Math.min(c.gainMax, c.gainMin + speed / c.speedRef);
    const k = speed / Math.max(1e-6, dist / dt);
    const vx = ((x - last.x) / dt) * k * c.inherit;
    const vy = ((y - last.y) / dt) * k * c.inherit;
    const step = c.cellW * 0.5;
    const n = Math.max(1, Math.ceil(dist / step));
    const amount = (gain * (dist / n)) / c.radius;
    // The sparse selection pattern drifts slowly so a long stroke never looks stencilled.
    const salt = Math.floor(timeMs / 450);
    for (let s = 1; s <= n; s++) {
      const u = s / n;
      this.depositDisc(last.x + (x - last.x) * u, last.y + (y - last.y) * u, amount, vx, vy, salt);
    }
  }

  private addTo(cx: number, cy: number, m: number, vx: number, vy: number, ox: number, oy: number, seed: number) {
    if (m <= 0 || cx < 0 || cy < 0 || cx >= this.cols || cy >= this.rows) return;
    const idx = cy * this.cols + cx;
    if (!this.nextMark[idx]) {
      if (this.nextCount >= this.cfg.maxCells) return;
      this.nextMark[idx] = 1;
      this.nextList[this.nextCount++] = idx;
    }
    this.nI[idx] += m;
    this.nVX[idx] += m * vx;
    this.nVY[idx] += m * vy;
    this.nOX[idx] += m * ox;
    this.nOY[idx] += m * oy;
    if (m > this.nMax[idx]) {
      this.nMax[idx] = m;
      this.nSeed[idx] = seed;
    }
  }

  /** Advance the simulation by dt seconds (clamped to cfg.maxDt). */
  step(dtIn: number) {
    const c = this.cfg;
    const dt = Math.min(c.maxDt, Math.max(0, dtIn));
    if (dt === 0 || this.count === 0) {
      this.t += dt;
      return;
    }
    const vmax = c.maxPointerSpeed * c.inherit + c.noiseAmp;
    const sub = Math.min(4, Math.max(1, Math.ceil((vmax * dt) / (0.9 * Math.min(c.cellW, c.cellH)))));
    const h = dt / sub;
    for (let i = 0; i < sub; i++) this.substep(h);
  }

  private substep(dt: number) {
    const c = this.cfg;
    this.t += dt;
    const decay = Math.exp((-LN2 * dt) / c.intensityHalfLife);
    const vdecay = Math.exp((-LN2 * dt) / c.velocityHalfLife);
    const share = Math.min(0.2, c.diffusion * dt);
    const ns = c.noiseScale;
    const nt = this.t * c.noiseSpeed;
    const scrambleP = c.scramble * dt;
    this.nextCount = 0;

    for (let i = 0; i < this.count; i++) {
      const idx = this.active[i];
      const I = this.I[idx] * decay;
      if (I < c.threshold) continue;
      const vx = this.VX[idx] * vdecay;
      const vy = this.VY[idx] * vdecay;
      const cx = idx % this.cols;
      const cy = (idx / this.cols) | 0;
      const px = (cx + 0.5) * c.cellW;
      const py = (cy + 0.5) * c.cellH;
      const nx = c.noiseAmp * Math.sin(px / ns + nt) * Math.cos((py / ns) * 1.3 - nt * 0.7);
      const ny = c.noiseAmp * Math.cos((px / ns) * 0.9 - nt * 1.1) * Math.sin(py / ns + nt * 0.8);
      let ox = this.OX[idx] + ((vx + nx) * dt * c.transport) / c.cellW;
      let oy = this.OY[idx] + ((vy + ny) * dt * c.transport) / c.cellH;
      let tx = cx;
      let ty = cy;
      if (ox > 0.5) {
        tx++;
        ox -= 1;
      } else if (ox < -0.5) {
        tx--;
        ox += 1;
      }
      if (oy > 0.5) {
        ty++;
        oy -= 1;
      } else if (oy < -0.5) {
        ty--;
        oy += 1;
      }
      if (this.rng() < scrambleP) this.seed[idx] = (this.rng() * 256) | 0;
      const g = this.seed[idx];
      const spread = I > 0.2 ? share : 0;
      this.addTo(tx, ty, I * (1 - spread), vx, vy, ox, oy, g);
      if (spread > 0) {
        const q = (I * spread) / 4;
        this.addTo(tx + 1, ty, q, vx * 0.6, vy * 0.6, 0, 0, (g + 37) & 255);
        this.addTo(tx - 1, ty, q, vx * 0.6, vy * 0.6, 0, 0, (g + 71) & 255);
        this.addTo(tx, ty + 1, q, vx * 0.6, vy * 0.6, 0, 0, (g + 113) & 255);
        this.addTo(tx, ty - 1, q, vx * 0.6, vy * 0.6, 0, 0, (g + 151) & 255);
      }
    }

    // Swap: keep cells above threshold, give newly reached cells a fresh glyph.
    for (let i = 0; i < this.count; i++) {
      const idx = this.active[i];
      this.I[idx] = 0;
      this.VX[idx] = 0;
      this.VY[idx] = 0;
      this.OX[idx] = 0;
      this.OY[idx] = 0;
    }
    const prevActive = this.isActive;
    let kept = 0;
    for (let i = 0; i < this.nextCount; i++) {
      const idx = this.nextList[i];
      const m = this.nI[idx];
      this.nextMark[idx] = 0;
      if (m >= c.threshold) {
        this.seed[idx] = this.nSeed[idx]; // the glyph travels with its content
        this.I[idx] = Math.min(1.4, m);
        this.VX[idx] = this.nVX[idx] / m;
        this.VY[idx] = this.nVY[idx] / m;
        this.OX[idx] = this.nOX[idx] / m;
        this.OY[idx] = this.nOY[idx] / m;
      }
      this.nI[idx] = 0;
      this.nVX[idx] = 0;
      this.nVY[idx] = 0;
      this.nOX[idx] = 0;
      this.nOY[idx] = 0;
      this.nMax[idx] = 0;
    }
    for (let i = 0; i < this.count; i++) prevActive[this.active[i]] = 0;
    for (let i = 0; i < this.nextCount; i++) {
      const idx = this.nextList[i];
      if (this.I[idx] > 0) {
        prevActive[idx] = 1;
        this.active[kept++] = idx;
      }
    }
    this.count = kept;
  }

  /** Visit every visible cell: centre (px), intensity, glyph seed, text-mask factor and x velocity. */
  forEachCell(cb: (x: number, y: number, intensity: number, seed: number, mask: number, vx: number) => void) {
    const { cellW, cellH } = this.cfg;
    for (let i = 0; i < this.count; i++) {
      const idx = this.active[i];
      const cx = idx % this.cols;
      const cy = (idx / this.cols) | 0;
      cb((cx + 0.5) * cellW, (cy + 0.5) * cellH, this.I[idx], this.seed[idx], this.mask[idx], this.VX[idx]);
    }
  }

  /** Sum of all intensity (tests / diagnostics). */
  totalIntensity() {
    let s = 0;
    for (let i = 0; i < this.count; i++) s += this.I[this.active[i]];
    return s;
  }

  /** Velocity stored in the cell under a point (tests / diagnostics). */
  velocityAt(x: number, y: number): [number, number] {
    const cx = Math.floor(x / this.cfg.cellW);
    const cy = Math.floor(y / this.cfg.cellH);
    const idx = cy * this.cols + cx;
    return [this.VX[idx], this.VY[idx]];
  }
}
