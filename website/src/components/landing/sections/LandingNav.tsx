import { useEffect, useState, type RefObject } from 'react';
import { cn } from '@/lib/utils';
import { HERO, LINKS, NAV } from '../content';
import { ExternalCta } from '../ui/ExternalCta';
import { LandingLink } from '../ui/LandingButton';
import { MenuPanel } from '../ui/MenuPanel';
import { SiteWordmark } from '../ui/SiteWordmark';

interface LandingNavProps {
  /** Dark tone while this element is under the navigation. Omit for pages without a dark hero. */
  heroRef?: RefObject<HTMLElement>;
  onCta: (name: string) => void;
}

const NAV_BOTTOM = 72;

/**
 * Floating navigation: the mark in a disc on the left, the “Menu” capsule in the centre, Setup guide
 * and Download on the right. No bar behind them; over the light page a soft blur band fades the
 * content that passes underneath.
 */
export function LandingNav({ heroRef, onCta }: LandingNavProps) {
  const [overHero, setOverHero] = useState(Boolean(heroRef));

  useEffect(() => {
    let raf = 0;
    const update = () => {
      raf = 0;
      const hero = heroRef?.current;
      setOverHero(hero ? hero.getBoundingClientRect().bottom > NAV_BOTTOM / 2 : false);
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    return () => {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [heroRef]);

  const tone = overHero ? 'dark' : 'light';

  return (
    <>
      <div aria-hidden="true" className="l-top-fade" style={{ opacity: overHero ? 0 : 1 }} />
      <header className="pointer-events-none fixed inset-x-0 top-0 z-50">
        <div className="relative mx-auto flex h-[72px] max-w-[1440px] items-center justify-between px-4 sm:px-8 lg:px-10">
          <a
            href={heroRef ? '#top' : '/'}
            aria-label={heroRef ? 'AIM — back to top' : 'AIM — home'}
            className={cn(
              'pointer-events-auto flex items-center gap-2.5 rounded-full transition-colors duration-300',
              tone === 'dark' ? 'text-[#F2F3F5]' : 'text-[#0B0B0C]',
            )}
          >
            <span
              className={cn(
                'grid h-11 w-11 place-items-center rounded-full transition-[background-color,box-shadow] duration-300',
                tone === 'dark'
                  ? 'bg-white/[0.08] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.12)]'
                  : 'bg-white/90 shadow-[0_0_0_1px_rgba(15,18,24,0.06),0_8px_24px_-10px_rgba(15,18,24,0.18)]',
              )}
            >
              <SiteWordmark size={24} tone={tone} animated markOnly />
            </span>
          </a>

          <div className="pointer-events-auto absolute left-1/2 top-[14px] z-10 -translate-x-1/2">
            <MenuPanel tone={tone} onCta={onCta} />
          </div>

          <div className="pointer-events-auto flex items-center gap-1.5">
            <LandingLink href={LINKS.guide} variant="ghost" tone={tone} size="md" className="hidden md:inline-flex" onClick={() => onCta('nav_guide')}>
              {NAV.guide}
            </LandingLink>
            <ExternalCta
              href={LINKS.macDownload}
              unavailableNoteId="nav-download-note"
              unavailableLabel={HERO.downloadUnavailable}
              unavailableBadge={HERO.soon}
              onActivate={(ok) => onCta(ok ? 'nav_download' : 'nav_download_unavailable')}
              variant="primary"
              tone={tone}
              size="md"
              className="hidden h-11 sm:inline-flex"
            >
              {NAV.download}
            </ExternalCta>
            <span id="nav-download-note" className="sr-only">
              {HERO.downloadUnavailable}
            </span>
          </div>
        </div>
      </header>
    </>
  );
}
