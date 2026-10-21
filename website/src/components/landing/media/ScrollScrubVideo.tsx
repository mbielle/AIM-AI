import { useEffect, useRef, useState, type MutableRefObject } from 'react';
import type { MotionValue } from 'motion/react';
import type { MediaSource } from '../media';

/** Debug measurements, shown with `?debug=scrub`. */
export interface ScrubStats {
  source: string;
  bytes: number;
  loadMs: number;
  duration: number;
  target: number;
  current: number;
  seeks: number;
  skipped: number;
  lastSeekMs: number;
  avgSeekMs: number;
  maxSeekMs: number;
  fps: number;
}

interface ScrollScrubVideoProps {
  sources: MediaSource[];
  /** Scroll progress of the scene, 0–1. */
  progress: MotionValue<number>;
  /** Start downloading (the scene is near the viewport). */
  load: boolean;
  /** Run the scrub loop (the scene is on screen). */
  active: boolean;
  /** Frame rate of the export, used to skip seeks smaller than half a frame. */
  fps?: number;
  className?: string;
  onReady?: () => void;
  onError?: () => void;
  statsRef?: MutableRefObject<ScrubStats | null>;
}

/** Test override: `?debug=scrub&scrubsrc=/path/to/clip.mp4` plays another file in the same scene. */
function overrideSource(): MediaSource | null {
  if (typeof window === 'undefined') return null;
  const p = new URLSearchParams(window.location.search);
  const src = p.get('scrubsrc');
  return p.get('debug') === 'scrub' && src ? { src, type: src.endsWith('.webm') ? 'video/webm' : 'video/mp4' } : null;
}

/**
 * A paused video whose position follows the scroll: scrolling down advances it, stopping holds the
 * frame, scrolling up rewinds. The scroll itself is never captured or slowed.
 *
 * The whole file is downloaded once (blob URL) so every seek is local; a new seek is only issued
 * after the previous one has completed (`seeked`) — Safari drops frames or stalls otherwise.
 */
export function ScrollScrubVideo({ sources, progress, load, active, fps = 30, className, onReady, onError, statsRef }: ScrollScrubVideoProps) {
  const video = useRef<HTMLVideoElement>(null);
  const [src, setSrc] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const callbacks = useRef({ onReady, onError });
  callbacks.current = { onReady, onError };

  // Choose a playable source and download it in full.
  useEffect(() => {
    if (!load || src) return;
    const v = video.current;
    if (!v) return;
    const chosen = overrideSource() ?? sources.find((s) => v.canPlayType(s.type) !== '');
    if (!chosen) {
      callbacks.current.onError?.();
      return;
    }
    let objectUrl: string | null = null;
    let cancelled = false;
    const t0 = performance.now();
    fetch(chosen.src)
      .then((r) => {
        if (!r.ok) throw new Error(String(r.status));
        return r.blob();
      })
      .then((blob) => {
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        if (statsRef) statsRef.current = { ...emptyStats(), source: chosen.src, bytes: blob.size, loadMs: Math.round(performance.now() - t0) };
        setSrc(objectUrl);
      })
      .catch(() => {
        // Fetch refused (e.g. cross-origin): stream it instead.
        if (!cancelled) setSrc(chosen.src);
      });
    return () => {
      cancelled = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
    // Sources are static per slot.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [load]);

  // Ready once the first frame can be shown; prime decoding (needed by iOS Safari to paint seeks).
  useEffect(() => {
    const v = video.current;
    if (!v || !src) return;
    const onLoaded = () => {
      v.play()
        .then(() => v.pause())
        .catch(() => {})
        .finally(() => {
          setReady(true);
          callbacks.current.onReady?.();
        });
    };
    const onErr = () => callbacks.current.onError?.();
    v.addEventListener('loadeddata', onLoaded, { once: true });
    v.addEventListener('error', onErr);
    return () => {
      v.removeEventListener('loadeddata', onLoaded);
      v.removeEventListener('error', onErr);
    };
  }, [src]);

  // Scrub loop: runs only while the scene is on screen.
  useEffect(() => {
    const v = video.current;
    if (!v || !ready || !active) return;
    let raf = 0;
    let smoothed = progress.get() * (v.duration || 0);
    let seeking = false;
    let seekStart = 0;
    let last = performance.now();
    let frames = 0;
    let fpsWindow = last;
    const s = statsRef?.current;

    const onSeeked = () => {
      seeking = false;
      if (!s) return;
      const ms = performance.now() - seekStart;
      s.lastSeekMs = Math.round(ms);
      s.maxSeekMs = Math.max(s.maxSeekMs, Math.round(ms));
      s.avgSeekMs = Math.round((s.avgSeekMs * (s.seeks - 1) + ms) / Math.max(1, s.seeks));
    };
    v.addEventListener('seeked', onSeeked);

    const tick = (now: number) => {
      const duration = v.duration || 0;
      // Slightly eased towards the scroll position, frame-rate independent; never more than a few frames behind.
      const target = Math.min(duration, Math.max(0, progress.get() * duration));
      const alpha = 1 - Math.pow(1 - 0.5, (now - last) / 16.67);
      last = now;
      smoothed += (target - smoothed) * alpha;
      if (Math.abs(target - smoothed) < 0.5 / fps) smoothed = target;

      if (Math.abs(v.currentTime - smoothed) > 0.5 / fps) {
        if (seeking) {
          if (s) s.skipped++;
        } else {
          seeking = true;
          seekStart = now;
          v.currentTime = smoothed;
          if (s) s.seeks++;
        }
      }

      if (s) {
        frames++;
        if (now - fpsWindow >= 500) {
          s.fps = Math.round((frames * 1000) / (now - fpsWindow));
          frames = 0;
          fpsWindow = now;
        }
        s.duration = duration;
        s.target = target;
        s.current = v.currentTime;
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      v.removeEventListener('seeked', onSeeked);
    };
  }, [ready, active, progress, fps, statsRef]);

  return (
    <video
      ref={video}
      src={src ?? undefined}
      className={className}
      muted
      playsInline
      preload="auto"
      disablePictureInPicture
      disableRemotePlayback
      aria-hidden="true"
      tabIndex={-1}
      style={{ opacity: ready ? 1 : 0, transition: 'opacity 200ms ease-out' }}
    />
  );
}

const emptyStats = (): ScrubStats => ({
  source: '',
  bytes: 0,
  loadMs: 0,
  duration: 0,
  target: 0,
  current: 0,
  seeks: 0,
  skipped: 0,
  lastSeekMs: 0,
  avgSeekMs: 0,
  maxSeekMs: 0,
  fps: 0,
});

/** Live readout of the scrub measurements (`?debug=scrub`). */
export function ScrubDebug({ statsRef, report }: { statsRef: MutableRefObject<ScrubStats | null>; report?: string | null }) {
  const [, force] = useState(0);
  useEffect(() => {
    const id = setInterval(() => force((n) => n + 1), 200);
    return () => clearInterval(id);
  }, []);
  const s = statsRef.current;
  if (!s) return <div className="l-scrub-debug">scrub: loading…</div>;
  const lag = Math.abs(s.target - s.current);
  return (
    <div className="l-scrub-debug">
      <div>{s.source.split('/').pop()}</div>
      <div>
        {(s.bytes / 1e6).toFixed(2)} MB · loaded in {s.loadMs} ms · {s.duration.toFixed(2)} s
      </div>
      <div>
        target {s.target.toFixed(3)} · current {s.current.toFixed(3)} · lag {(lag * 1000).toFixed(0)} ms
      </div>
      <div>
        seeks {s.seeks} · skipped {s.skipped} · seek {s.lastSeekMs} ms (avg {s.avgSeekMs}, max {s.maxSeekMs})
      </div>
      <div>loop {s.fps} fps</div>
      {report && <div style={{ marginTop: 6, maxWidth: 520, color: '#9fe3b0' }}>AUTOTEST · {report}</div>}
    </div>
  );
}
