/**
 * Dev-only self-test of the scroll scrub (`?debug=scrub&autotest=1`), for browsers that cannot be
 * driven from outside (Safari). Scrolls the page itself through the product story — slow, fast
 * flick, abrupt reversals, stops — sampling every frame the gap between the scroll target and the
 * frame the video shows. Same metrics as scripts/media/test-scrub.mjs. Programmatic scrolling is
 * not a trackpad: a manual pass is still required.
 */

interface Sample {
  t: number;
  target: number;
  shown: number;
  phase: string;
}

export interface ScrubReport {
  ua: string;
  slowDelayP95: number;
  fastDelayP95: number;
  reverseDelayP95: number;
  slowFramesP95: number;
  settleMs: number[];
  samples: number;
  measured?: string;
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function runScrubAutotest(section: HTMLElement, video: HTMLVideoElement): Promise<ScrubReport> {
  const top = section.getBoundingClientRect().top + window.scrollY;
  const usable = section.offsetHeight - window.innerHeight;
  window.scrollTo(0, top);
  await wait(800);

  const samples: Sample[] = [];
  const stops: Array<{ t: number }> = [];
  let phase = 'start';
  let running = true;
  // Frame actually presented on screen (requestVideoFrameCallback), not just the requested time.
  type RVFC = { requestVideoFrameCallback?: (cb: (now: number, meta: { mediaTime: number }) => void) => number };
  const v: RVFC = video;
  let presented = video.currentTime;
  const presentedSource = v.requestVideoFrameCallback ? 'presented' : 'currentTime';
  if (v.requestVideoFrameCallback) {
    const onFrame = (_: number, meta: { mediaTime: number }) => {
      presented = meta.mediaTime;
      if (running) v.requestVideoFrameCallback!(onFrame);
    };
    v.requestVideoFrameCallback(onFrame);
  }
  const sample = () => {
    const r = section.getBoundingClientRect();
    const p = Math.min(1, Math.max(0, -r.top / usable));
    samples.push({ t: performance.now(), target: p * video.duration, shown: v.requestVideoFrameCallback ? presented : video.currentTime, phase });
    if (running) requestAnimationFrame(sample);
  };
  requestAnimationFrame(sample);

  /** Scrolls `dist` px at `speed` px/s, one step per frame. */
  const glide = (dist: number, speed: number) =>
    new Promise<void>((resolve) => {
      const start = performance.now();
      const y0 = window.scrollY;
      const step = (now: number) => {
        const done = Math.min(Math.abs(dist), ((now - start) / 1000) * speed);
        window.scrollTo(0, y0 + Math.sign(dist) * done);
        if (done < Math.abs(dist)) requestAnimationFrame(step);
        else resolve();
      };
      requestAnimationFrame(step);
    });
  const stop = async (ms: number) => {
    phase = 'stop';
    stops.push({ t: performance.now() });
    await wait(ms);
  };

  phase = 'slow';
  await glide(usable * 0.35, 1300);
  await stop(700);
  phase = 'fast';
  await glide(usable * 0.45, 8000);
  await stop(700);
  phase = 'reverse';
  await glide(-usable * 0.4, 6000);
  for (let i = 0; i < 3; i++) {
    await glide(400, 5000);
    await glide(-400, 5000);
  }
  await stop(900);
  running = false;

  return { ...summarise(samples, stops), measured: presentedSource };
}

function summarise(samples: Sample[], stops: Array<{ t: number }>): ScrubReport {
  const frame = 1 / 30;
  const delays: Record<string, number[]> = {};
  const frames: number[] = [];
  samples.forEach((s, i) => {
    let delay = 0;
    if (Math.abs(s.target - s.shown) >= frame) {
      delay = 999;
      for (let k = i; k > 0; k--) {
        const a = samples[k - 1].target;
        const b = samples[k].target;
        if ((s.shown - a) * (s.shown - b) <= 0) {
          delay = s.t - samples[k - 1].t;
          break;
        }
      }
    }
    (delays[s.phase] ??= []).push(delay);
    if (s.phase === 'slow') frames.push(Math.abs(s.target - s.shown) * 30);
  });
  const p95 = (arr: number[] = []) => {
    const a = [...arr].sort((x, y) => x - y);
    return Math.round((a[Math.floor(0.95 * (a.length - 1))] ?? 0) * 10) / 10;
  };
  const settleMs = stops.map(({ t }) => {
    const after = samples.filter((s) => s.t > t);
    const ok = after.find((_, k) => after.slice(k, k + 5).every((y) => Math.abs(y.target - y.shown) < frame));
    return ok ? Math.round(ok.t - t) : -1;
  });
  return {
    ua: navigator.userAgent.includes('Chrome') ? 'Chrome' : navigator.userAgent.includes('Safari') ? 'Safari' : navigator.userAgent,
    slowDelayP95: p95(delays.slow),
    fastDelayP95: p95(delays.fast),
    reverseDelayP95: p95(delays.reverse),
    slowFramesP95: p95(frames),
    settleMs,
    samples: samples.length,
  };
}
