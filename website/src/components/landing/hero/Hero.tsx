import { Monitor } from 'lucide-react';
import { lazy, Suspense, useRef, useState, type RefObject } from 'react';
import { AimMascot } from '@/components/mascot/AimMascot';
import { HERO, LINKS, REMOTE } from '../content';
import { ExternalCta, isAvailable } from '../ui/ExternalCta';
import { LandingLink } from '../ui/LandingButton';
import { CodeTrailCanvas } from './CodeTrailCanvas';
import { DEFAULT_TRAIL_CONFIG, type TrailConfig } from './trailConfig';

const TUNER_ENABLED = import.meta.env.DEV || import.meta.env.VITE_TRAIL_TUNER === '1';
const TrailTuner = TUNER_ENABLED ? lazy(() => import('./TrailTuner')) : null;

interface HeroProps {
  heroRef: RefObject<HTMLElement>;
  onCta: (name: string) => void;
}

/** Near-black, almost empty at rest. Moving the mouse leaves a brief glyph disturbance. */
export function Hero({ heroRef, onCta }: HeroProps) {
  const titleRef = useRef<HTMLHeadingElement>(null);
  const ctaRef = useRef<HTMLDivElement>(null);
  const markRef = useRef<HTMLDivElement>(null);
  const [maskRefs] = useState(() => [markRef, titleRef, ctaRef]);
  const [config] = useState<TrailConfig>(() => ({ ...DEFAULT_TRAIL_CONFIG }));
  const [tune] = useState(() => TUNER_ENABLED && typeof window !== 'undefined' && new URLSearchParams(window.location.search).has('tune'));
  const downloadAvailable = isAvailable(LINKS.macDownload);

  return (
    <section
      ref={heroRef}
      aria-labelledby="hero-title"
      className="relative isolate flex min-h-[100svh] flex-col overflow-hidden bg-[#0A0A0B] text-[#F2F3F5]"
    >
      <CodeTrailCanvas hostRef={heroRef} maskRefs={maskRefs} config={config} />

      {/* One grouped block, slightly above the optical centre; capped so it never stretches on ultrawide. */}
      <div className="relative z-10 mx-auto flex w-full max-w-[1200px] flex-1 flex-col items-center justify-center px-5 pb-[13vh] pt-28 text-center sm:px-8">
        {/* Stable slot for the brand mark: the AIM companion. It greets once, follows the pointer,
            and dozes off after a long quiet moment (pointer movement wakes it). */}
        <div ref={markRef} className="-mt-6 mb-2 flex h-[150px] w-[150px] items-center justify-center" data-slot="hero-mark">
          <AimMascot
            size={150}
            variant="companion"
            followPointer
            reaction={{ type: 'greet', key: 'hero' }}
            bodyColor="#F2F3F5"
            eyeColor="#0A0A0B"
            seed={31}
          />
        </div>
        <h1 id="hero-title" ref={titleRef} className="l-display max-w-[17ch] text-balance lg:max-w-none">
          {HERO.title}
        </h1>
        <p className="l-lead mt-6 max-w-[34ch] text-pretty text-[#9AA0A8] sm:max-w-[52ch]">{HERO.subtitle}</p>

        <div ref={ctaRef} className="mt-11 flex flex-wrap items-center justify-center gap-3">
          <ExternalCta
            href={LINKS.macDownload}
            unavailableNoteId="hero-download-note"
            unavailableLabel={HERO.downloadUnavailable}
            unavailableBadge={HERO.soon}
            onActivate={(ok) => onCta(ok ? 'hero_download' : 'hero_download_unavailable')}
            variant="primary"
            tone="dark"
            size="xl"
          >
            <Monitor className="-mt-0.5 h-4 w-4" aria-hidden="true" />
            {HERO.download}
          </ExternalCta>
          <LandingLink href={LINKS.guide} variant="secondary" tone="dark" size="xl" onClick={() => onCta('hero_guide')}>
            {HERO.guide}
          </LandingLink>
        </div>
        {!downloadAvailable && (
          <span id="hero-download-note" className="sr-only">
            {HERO.downloadUnavailable}
          </span>
        )}

        {LINKS.source && <a href={LINKS.source} target="_blank" rel="noopener noreferrer" className="mt-6 rounded-sm text-[14px] text-[#B8BDC5] underline underline-offset-4 transition-colors hover:text-white">Browse the source code</a>}
        <p className="mt-8 text-[14px] text-[#9AA0A8]">{HERO.free}</p>
        <p className="mt-1.5 text-[13px] text-[#9AA0A8]">{HERO.requirements}</p>
        {!LINKS.appStore && <p className="mt-2 max-w-[48ch] text-[13px] text-[#9AA0A8]">AIM for iPhone: {REMOTE.appStoreUnavailable}</p>}
      </div>

      {tune && TrailTuner && (
        <Suspense fallback={null}>
          <TrailTuner config={config} />
        </Suspense>
      )}
    </section>
  );
}
