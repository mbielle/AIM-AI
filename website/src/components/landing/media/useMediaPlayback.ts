import { useEffect, useState, type RefObject } from 'react';
import type { MediaMode } from '../media';

/** True once the element comes within `margin` of the viewport (stays true: used to start loading). */
export function useNearViewport(ref: RefObject<Element>, margin = '100% 0px') {
  const [near, setNear] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el || near) return;
    const io = new IntersectionObserver(([e]) => e.isIntersecting && setNear(true), { rootMargin: margin });
    io.observe(el);
    return () => io.disconnect();
  }, [ref, margin, near]);
  return near;
}

/** Whether at least `threshold` of the element is visible right now. */
export function useInViewport(ref: RefObject<Element>, threshold = 0.4) {
  const [inView, setInView] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setInView(e.isIntersecting), { threshold });
    io.observe(el);
    return () => io.disconnect();
  }, [ref, threshold]);
  return inView;
}

interface PlaybackOptions {
  mode: MediaMode;
  /** Hover mode: whether the trigger is currently hovered / selected. */
  active?: boolean;
  /** Visible mode: whether the frame is on screen. */
  inView?: boolean;
  /** Playback allowed at all (false with reduced motion until the visitor presses Play). */
  allowed: boolean;
}

/**
 * Playback policy, independent of how the frame itself moves: hover media play while active and
 * rewind when left; visible media play while on screen; nothing plays in a hidden tab.
 * Scrub and still media are never played here.
 */
export function useMediaPlayback(video: RefObject<HTMLVideoElement>, { mode, active, inView, allowed }: PlaybackOptions) {
  const [tabVisible, setTabVisible] = useState(() => typeof document === 'undefined' || document.visibilityState === 'visible');

  useEffect(() => {
    const onChange = () => setTabVisible(document.visibilityState === 'visible');
    document.addEventListener('visibilitychange', onChange);
    return () => document.removeEventListener('visibilitychange', onChange);
  }, []);

  const shouldPlay = allowed && tabVisible && ((mode === 'hover' && Boolean(active)) || (mode === 'visible' && Boolean(inView)));

  useEffect(() => {
    const v = video.current;
    if (!v || mode === 'scrub' || mode === 'still') return;
    if (shouldPlay) {
      v.play().catch(() => {
        /* Autoplay refused or source missing: the poster stays. */
      });
    } else {
      v.pause();
      if (mode === 'hover' && !active && v.currentTime > 0) v.currentTime = 0;
    }
  }, [video, mode, shouldPlay, active]);

  return shouldPlay;
}
