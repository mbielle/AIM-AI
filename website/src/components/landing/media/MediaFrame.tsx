import { useRef, useState, type MutableRefObject } from 'react';
import { useReducedMotion, type MotionValue } from 'motion/react';
import { Play, Pause } from 'lucide-react';
import { cn } from '@/lib/utils';
import { MEDIA, type MediaSlotId } from '../media';
import { MediaFallback } from './MediaFallback';
import { ScrollScrubVideo, type ScrubStats } from './ScrollScrubVideo';
import { useInViewport, useMediaPlayback, useNearViewport } from './useMediaPlayback';

interface MediaFrameProps {
  slot: MediaSlotId;
  /**
   * - `window`: an app window capture (the media includes its own title bar): window radius and shadow.
   * - `card`: a cropped detail inside a card or preview: softer radius, hairline, no outer shadow.
   * - `bare`: no frame of its own (the parent provides it).
   */
  variant?: 'window' | 'card' | 'bare';
  /** Hover mode: whether the trigger is active. */
  active?: boolean;
  /** Scrub mode: scroll progress 0–1 and whether the scene is on screen. */
  progress?: MotionValue<number>;
  scrubActive?: boolean;
  scrubStats?: MutableRefObject<ScrubStats | null>;
  /** Load the media regardless of position (e.g. a preview that is about to open). */
  eager?: boolean;
  className?: string;
}

/**
 * The container every product visual sits in. Its box comes from the slot's aspect ratio, so a
 * placeholder, a poster and the final capture all occupy exactly the same space (no layout jump,
 * no letterboxing: media cover the box). Shows the poster at once, fades the media in once it can
 * play, keeps the poster or the temporary mockup on error. With reduced motion nothing plays until
 * the visitor presses Play.
 */
export function MediaFrame({ slot: id, variant = 'card', active, progress, scrubActive = false, scrubStats, eager, className }: MediaFrameProps) {
  const slot = MEDIA[id];
  const box = useRef<HTMLDivElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const reduced = useReducedMotion() ?? false;
  const near = useNearViewport(box);
  const inView = useInViewport(box, 0.4);
  const [ready, setReady] = useState(false);
  const [failed, setFailed] = useState(false);
  const [userPlay, setUserPlay] = useState(false);
  const [posterFailed, setPosterFailed] = useState(false);

  const hasVideo = Boolean(slot.sources?.length) && slot.mode !== 'still';
  const isScrub = slot.mode === 'scrub' && hasVideo && Boolean(progress) && !reduced;
  // A scrub recording outside its scroll scene (small screens, reduced motion) is just its poster.
  const isVideo = hasVideo && (slot.mode !== 'scrub' || isScrub);
  const load = (near || Boolean(eager)) && !failed;
  const showMedia = isVideo ? !failed : Boolean(slot.image) && !failed;
  const playing = useMediaPlayback(video, { mode: slot.mode, active, inView, allowed: !reduced || userPlay });

  return (
    <div
      ref={box}
      className={cn(
        'relative isolate w-full overflow-hidden',
        variant === 'window' && 'l-window rounded-[10px] bg-[#EEEEED] sm:rounded-[12px]',
        variant === 'card' && 'l-media-card rounded-[14px]',
        className,
      )}
      style={{ aspectRatio: String(slot.aspect) }}
    >
      {/* Under-layer: temporary mockup, or the poster. Stays until the media can be shown. */}
      <div {...(slot.alt ? { role: 'img', 'aria-label': slot.verifiedCapture ? slot.alt : `Illustrative interface: ${slot.alt}` } : { 'aria-hidden': true })} className="absolute inset-0">
        {slot.poster && !posterFailed ? (
          <img
            src={slot.poster}
            alt=""
            className="absolute inset-0 h-full w-full object-cover"
            style={{ objectPosition: slot.position }}
            decoding="async"
            onError={() => setPosterFailed(true)}
          />
        ) : (
          <div aria-hidden="true">
            <MediaFallback fallback={slot.fallback} />
          </div>
        )}
      </div>

      {showMedia && isScrub && progress && (
        <ScrollScrubVideo
          sources={slot.sources!}
          progress={progress}
          load={load}
          active={scrubActive}
          statsRef={scrubStats}
          className="absolute inset-0 h-full w-full object-cover"
          onReady={() => setReady(true)}
          onError={() => setFailed(true)}
        />
      )}

      {showMedia && isVideo && !isScrub && (
        <video
          ref={video}
          className="absolute inset-0 h-full w-full object-cover transition-opacity duration-200 ease-out"
          style={{ objectPosition: slot.position, opacity: ready ? 1 : 0 }}
          poster={slot.poster}
          muted
          loop
          playsInline
          preload={load ? 'auto' : 'none'}
          disablePictureInPicture
          disableRemotePlayback
          aria-hidden="true"
          tabIndex={-1}
          onLoadedData={() => setReady(true)}
          onError={() => setFailed(true)}
        >
          {load && slot.sources!.map((s) => <source key={s.src} src={s.src} type={s.type} onError={(e) => isLastSource(e.currentTarget) && setFailed(true)} />)}
        </video>
      )}

      {showMedia && !isVideo && slot.image && (
        <img
          src={slot.image}
          alt=""
          aria-hidden="true"
          loading="lazy"
          decoding="async"
          className="absolute inset-0 h-full w-full object-cover transition-opacity duration-200 ease-out"
          style={{ objectPosition: slot.position, opacity: ready ? 1 : 0 }}
          onLoad={() => setReady(true)}
          onError={() => setFailed(true)}
        />
      )}

      {!slot.verifiedCapture && <span className="pointer-events-none absolute bottom-2 left-2 z-10 rounded-md bg-white/90 px-2 py-1 text-[10px] font-medium text-[#5D6168] shadow-sm">Illustrative interface · sample data</span>}

      {/* Reduced motion: nothing moves until asked. */}
      {reduced && isVideo && !failed && slot.mode !== 'scrub' && (
        <button
          type="button"
          onClick={() => setUserPlay((p) => !p)}
          className="absolute bottom-3 right-3 z-10 grid h-9 w-9 place-items-center rounded-full bg-white/90 text-[#0B0B0C] shadow-[0_0_0_1px_rgba(11,11,12,0.08),0_6px_16px_-8px_rgba(11,11,12,0.3)]"
          aria-label={playing ? 'Pause video' : 'Play video'}
        >
          {playing ? <Pause className="h-4 w-4" strokeWidth={2} /> : <Play className="ml-0.5 h-4 w-4" strokeWidth={2} />}
        </button>
      )}
    </div>
  );
}

/** A <source> error only means failure once no other source is left to try. */
const isLastSource = (el: HTMLSourceElement) => !el.nextElementSibling;
