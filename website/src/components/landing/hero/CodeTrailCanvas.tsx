import { useEffect, useRef, type RefObject } from 'react';
import { CodeTrail, type Rect } from './codeTrail';
import type { TrailConfig } from './trailConfig';

/** A small, coherent family: dashes for the body of the wake, chevrons where it is strongest. */
const GLYPHS = ['-', '_', '>', '<'];
const DASH = 0;
const UNDERSCORE = 1;
const RIGHT = 2;
const LEFT = 3;
const COOL = '#AEB9C8';
const BRIGHT = '#E6EBF2';

export const TRAIL_CONFIG_EVENT = 'aim-trail-config';

interface CodeTrailCanvasProps {
  /** Element whose pointer movement drives the trail (the hero section). */
  hostRef: RefObject<HTMLElement>;
  /** Elements over which the trail is dimmed (headline, buttons). */
  maskRefs?: Array<RefObject<HTMLElement>>;
  config: TrailConfig;
}

/** Pre-render every glyph once, in two tones, so a frame is only drawImage calls. */
function buildAtlas(cfg: TrailConfig, dpr: number) {
  const gw = cfg.cellW;
  const gh = cfg.cellH;
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(GLYPHS.length * gw * dpr);
  canvas.height = Math.ceil(gh * 2 * dpr);
  const ctx = canvas.getContext('2d')!;
  ctx.scale(dpr, dpr);
  ctx.font = `500 ${cfg.fontPx}px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  [COOL, BRIGHT].forEach((color, row) => {
    ctx.fillStyle = color;
    GLYPHS.forEach((g, i) => ctx.fillText(g, i * gw + gw / 2, row * gh + gh / 2 + 0.5));
  });
  return canvas;
}

/** Faint: dashes. Mid: mostly dashes, a few underscores. Strong: chevrons pointing the way the cell drifts. */
const glyphIndex = (intensity: number, seed: number, vx: number) => {
  if (intensity < 0.3) return DASH;
  if (intensity < 0.58) return seed % 7 === 0 ? UNDERSCORE : DASH;
  if (seed % 9 === 0) return DASH;
  return vx < 0 ? LEFT : RIGHT;
};

/**
 * Canvas layer for the hero: empty and idle at rest, a local glyph disturbance while the mouse
 * moves, fully cleared (and the frame loop stopped) once the trail has dissipated.
 */
export function CodeTrailCanvas({ hostRef, maskRefs = [], config }: CodeTrailCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    const canvas = canvasRef.current;
    if (!host || !canvas) return;

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
    const fine = window.matchMedia('(hover: hover) and (pointer: fine)');
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const engine = new CodeTrail(1, 1, config, 7);
    let dpr = Math.min(2, window.devicePixelRatio || 1);
    let atlas = buildAtlas(config, dpr);
    let raf = 0;
    let last = 0;
    let visible = true;

    const setState = (state: 'idle' | 'running' | 'off') => {
      canvas.dataset.trailState = state;
      canvas.dataset.trailCells = String(engine.activeCount());
    };
    const enabled = () => !reduce.matches && fine.matches;

    const updateMask = () => {
      const base = canvas.getBoundingClientRect();
      const rects: Rect[] = maskRefs
        .map((r) => r.current?.getBoundingClientRect())
        .filter((r): r is DOMRect => Boolean(r))
        .map((r) => ({ x: r.left - base.left, y: r.top - base.top, w: r.width, h: r.height }));
      engine.setMask(rects);
    };

    const resize = () => {
      const { width, height } = host.getBoundingClientRect();
      dpr = Math.min(2, window.devicePixelRatio || 1);
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      engine.resize(width, height);
      atlas = buildAtlas(config, dpr);
      updateMask();
      stop();
    };

    const draw = () => {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      const { cellW: gw, cellH: gh, alphaMax, alphaGamma } = config;
      const sw = gw * dpr;
      const sh = gh * dpr;
      engine.forEachCell((x, y, intensity, seed, mask, vx) => {
        const a = Math.pow(Math.min(1, intensity), alphaGamma) * alphaMax * mask;
        if (a < 0.012) return;
        const g = glyphIndex(intensity, seed, vx);
        const row = intensity > 0.85 ? 1 : 0;
        ctx.globalAlpha = a;
        ctx.drawImage(atlas, g * sw, row * sh, sw, sh, (x - gw / 2) * dpr, (y - gh / 2) * dpr, sw, sh);
      });
      ctx.globalAlpha = 1;
    };

    function stop() {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      engine.clear();
      engine.resetPointer();
      ctx!.setTransform(1, 0, 0, 1, 0, 0);
      ctx!.clearRect(0, 0, canvas!.width, canvas!.height);
      setState(enabled() ? 'idle' : 'off');
    }

    const frame = (ts: number) => {
      const dt = (ts - last) / 1000;
      last = ts;
      engine.step(dt);
      if (engine.activeCount() === 0) {
        stop();
        return;
      }
      draw();
      setState('running');
      raf = requestAnimationFrame(frame);
    };

    const start = () => {
      if (raf) return;
      last = performance.now();
      raf = requestAnimationFrame(frame);
    };

    const onMove = (e: PointerEvent) => {
      if (e.pointerType !== 'mouse' || !enabled() || !visible || document.hidden) return;
      const r = canvas.getBoundingClientRect();
      engine.pointer(e.clientX - r.left, e.clientY - r.top, e.timeStamp);
      if (engine.activeCount() > 0) start();
    };
    const onLeaveOrEnter = () => engine.resetPointer();
    const onVisibility = () => {
      if (document.hidden) stop();
    };
    const onPrefChange = () => stop();

    const ro = new ResizeObserver(resize);
    ro.observe(host);
    const io = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (!visible) stop();
    });
    io.observe(host);
    host.addEventListener('pointermove', onMove, { passive: true });
    host.addEventListener('pointerleave', onLeaveOrEnter);
    host.addEventListener('pointerenter', onLeaveOrEnter);
    document.addEventListener('visibilitychange', onVisibility);
    reduce.addEventListener('change', onPrefChange);
    fine.addEventListener('change', onPrefChange);
    const onConfig = () => resize();
    window.addEventListener(TRAIL_CONFIG_EVENT, onConfig);
    resize();
    // The headline can move once web fonts arrive: recompute where the trail must stay quiet.
    document.fonts?.ready.then(updateMask).catch(() => {});

    return () => {
      stop();
      ro.disconnect();
      io.disconnect();
      host.removeEventListener('pointermove', onMove);
      host.removeEventListener('pointerleave', onLeaveOrEnter);
      host.removeEventListener('pointerenter', onLeaveOrEnter);
      document.removeEventListener('visibilitychange', onVisibility);
      reduce.removeEventListener('change', onPrefChange);
      fine.removeEventListener('change', onPrefChange);
      window.removeEventListener(TRAIL_CONFIG_EVENT, onConfig);
    };
  }, [hostRef, maskRefs, config]);

  return (
    <canvas
      ref={canvasRef}
      aria-hidden="true"
      className="pointer-events-none absolute inset-0"
      data-trail-state="idle"
      data-trail-cells="0"
    />
  );
}

export default CodeTrailCanvas;
