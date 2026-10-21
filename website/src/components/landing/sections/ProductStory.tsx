import { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion, useMotionValueEvent, useReducedMotion, useScroll } from 'motion/react';
import { cn } from '@/lib/utils';
import { STORY } from '../content';
import { MediaFrame } from '../media/MediaFrame';
import { ScrubDebug, type ScrubStats } from '../media/ScrollScrubVideo';
import { useInViewport } from '../media/useMediaPlayback';

const params = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : null;
const DEBUG = params?.get('debug') === 'scrub';
const AUTOTEST = DEBUG && params?.has('autotest');

function useMinWidth(px: number) {
  const [match, setMatch] = useState(() => typeof window !== 'undefined' && window.matchMedia(`(min-width: ${px}px)`).matches);
  useEffect(() => {
    const mq = window.matchMedia(`(min-width: ${px}px)`);
    const onChange = () => setMatch(mq.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, [px]);
  return match;
}

const stepAt = (p: number) => STORY.steps.reduce((acc, s, i) => (p >= s.at ? i : acc), 0);

/**
 * The main product demo. A bounded scroll section with a sticky stage: the window stays in view
 * while scrolling moves the recording forward or back; at the end the stage leaves with its
 * section. Step titles live in the page, above the window. On small screens and with reduced
 * motion the stage is static: cover image and the steps as text.
 */
export function ProductStory() {
  const section = useRef<HTMLElement>(null);
  const reduced = useReducedMotion() ?? false;
  const wide = useMinWidth(768);
  const scrub = wide && !reduced;
  const inView = useInViewport(section, 0);
  const stats = useRef<ScrubStats | null>(null);
  const { scrollYProgress } = useScroll({ target: section, offset: ['start start', 'end end'] });
  const [step, setStep] = useState(0);

  const [report, setReport] = useState<string | null>(null);

  // Measurements readable by scripts/media/test-scrub.mjs.
  useEffect(() => {
    if (DEBUG) (window as unknown as { __aimScrub?: typeof stats }).__aimScrub = stats;
  }, []);

  // Dev self-test (`&autotest=1`): waits for the clip, scrolls through the scene, shows the report.
  useEffect(() => {
    if (!AUTOTEST || !scrub) return;
    let cancelled = false;
    (async () => {
      const el = section.current;
      if (!el) return;
      window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY);
      while (!cancelled && !(stats.current?.duration && el.querySelector('video')?.readyState === 4)) await new Promise((r) => setTimeout(r, 200));
      if (cancelled) return;
      const { runScrubAutotest } = await import('../media/scrubAutotest');
      const r = await runScrubAutotest(el, el.querySelector('video')!);
      const line = `${r.ua} · ${stats.current?.source.split('/').pop()} · delay p95 slow ${r.slowDelayP95} / fast ${r.fastDelayP95} / reverse ${r.reverseDelayP95} ms · slow lag ${r.slowFramesP95} fr · settle ${r.settleMs.join('/')} ms · seek avg ${stats.current?.avgSeekMs} max ${stats.current?.maxSeekMs} ms`;
      const payload = JSON.stringify({ ...r, stats: stats.current });
      console.info('[scrub autotest]', payload);
      // Optional local collector (dev): `&report=<port>` posts the report to localhost:<port>.
      const port = params?.get('report');
      if (port && /^\d+$/.test(port)) fetch(`http://localhost:${port}/report`, { method: 'POST', body: payload, mode: 'no-cors' }).catch(() => {});
      if (!cancelled) setReport(line);
    })();
    return () => {
      cancelled = true;
    };
  }, [scrub]);

  useMotionValueEvent(scrollYProgress, 'change', (p) => {
    const next = stepAt(p);
    if (next !== step) setStep(next);
  });

  if (!scrub) {
    return (
      <section id="product" aria-labelledby="story-title" className="relative scroll-mt-[var(--l-nav)] px-4 pb-24 pt-20 sm:px-8">
        <h2 id="story-title" className="l-h2 mx-auto max-w-[18ch] text-balance text-center">
          {STORY.steps[0].title} <span className="l-title-muted">{STORY.steps[1].title}</span>
        </h2>
        <div className="mx-auto mt-10 w-full max-w-[1180px]">
          <MediaFrame slot="story" variant="window" />
        </div>
        <ol className="mx-auto mt-10 grid max-w-[1180px] gap-6 sm:grid-cols-2 lg:grid-cols-5">
          {STORY.steps.map((s, i) => (
            <li key={s.title} className="border-t border-black/[0.08] pt-4">
              <p className="l-mono text-[12px] text-[#8E939B]">{String(i + 1).padStart(2, '0')}</p>
              <p className="mt-2 text-[16px] font-medium tracking-[-0.01em] text-[#0B0B0C]">{s.title}</p>
              <p className="mt-1 text-[14px] leading-relaxed text-[#5D6168]">{s.sub}</p>
            </li>
          ))}
        </ol>
        <p className="mt-8 text-center text-[12.5px] text-[#8E939B]">{STORY.caption}</p>
      </section>
    );
  }

  const current = STORY.steps[step];

  return (
    <section ref={section} id="product" aria-labelledby="story-title" className="relative" style={{ height: '400vh' }}>
      <h2 id="story-title" className="sr-only">
        {STORY.title}
      </h2>
      <div className="sticky top-0 flex h-[100svh] flex-col items-center justify-center px-6 pb-8 pt-[calc(var(--l-nav)+8px)]">
        {/* Step title: fixed height so the window never moves when it changes. */}
        <div className="relative h-[112px] w-full max-w-[900px] text-center" aria-live="polite">
          <AnimatePresence initial={false}>
            <motion.div
              key={step}
              className="absolute inset-x-0 top-0"
              initial={{ opacity: 0, y: 10, filter: 'blur(4px)' }}
              animate={{ opacity: 1, y: 0, filter: 'blur(0px)' }}
              exit={{ opacity: 0, y: -10, filter: 'blur(4px)' }}
              transition={{ duration: 0.32, ease: [0.22, 1, 0.36, 1] }}
            >
              <p className="l-h2 text-balance">{current.title}</p>
              <p className="mt-3 text-[17px] leading-relaxed text-[#6B6F76]">{current.sub}</p>
            </motion.div>
          </AnimatePresence>
        </div>

        {/* Bounded by width and by the height left under the title, so the window is never cropped. */}
        <div className="mt-6" style={{ width: 'min(88vw, 1180px, calc((100svh - var(--l-nav) - 230px) * 1.6))' }}>
          <MediaFrame slot="story" variant="window" progress={scrollYProgress} scrubActive={inView} scrubStats={stats} eager={inView} />
        </div>

        <div className="mt-5 flex items-center gap-4">
          <ol className="flex items-center gap-1.5" aria-hidden="true">
            {STORY.steps.map((s, i) => (
              <li key={s.title} className={cn('h-[3px] rounded-full transition-all duration-300', i === step ? 'w-6 bg-[#0B0B0C]' : 'w-3 bg-black/15')} />
            ))}
          </ol>
          <p className="text-[12.5px] text-[#8E939B]">{STORY.caption}</p>
        </div>
      </div>
      {DEBUG && <ScrubDebug statsRef={stats} report={report} />}
    </section>
  );
}
