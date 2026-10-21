import { motion, useReducedMotion } from 'motion/react';
import { CTA_FINAL, HERO, LINKS } from '../content';
import { Monitor } from 'lucide-react';
import { MediaFrame } from '../media/MediaFrame';
import { ExternalCta } from '../ui/ExternalCta';
import { LandingLink } from '../ui/LandingButton';
import type { MediaSlotId } from '../media';

const FAN: Array<{ slot: MediaSlotId; rotate: number; y: number }> = [
  { slot: 'cta-1', rotate: -12, y: 26 },
  { slot: 'cta-2', rotate: -6, y: 8 },
  { slot: 'cta-3', rotate: 0, y: 0 },
  { slot: 'cta-4', rotate: 6, y: 8 },
  { slot: 'cta-5', rotate: 12, y: 26 },
];

/** Closing call to action: a small fan of AIM captures, one sentence and the real actions. */
export function FinalCta({ onCta }: { onCta: (name: string) => void }) {
  const reduced = useReducedMotion() ?? false;

  return (
    <section aria-labelledby="final-cta-title" className="relative overflow-x-clip px-4 pb-32 pt-8 sm:px-8 sm:pb-40">
      <div className="mx-auto flex w-full max-w-[1240px] flex-col items-center text-center">
        <motion.ul
          aria-hidden="true"
          className="flex items-end justify-center"
          initial={reduced ? false : 'hidden'}
          whileInView="shown"
          viewport={{ once: true, margin: '0px 0px -15% 0px' }}
        >
          {FAN.map((c, i) => (
            <motion.li
              key={c.slot}
              className="-mx-3 w-[clamp(92px,15vw,168px)] sm:-mx-4"
              style={{ zIndex: i === 2 ? 3 : i === 1 || i === 3 ? 2 : 1 }}
              variants={{
                hidden: { opacity: 0, y: c.y + 40, rotate: 0 },
                shown: { opacity: 1, y: c.y, rotate: c.rotate, transition: { duration: 0.8, delay: 0.05 * Math.abs(i - 2), ease: [0.22, 1, 0.36, 1] } },
              }}
              whileHover={reduced ? undefined : { y: c.y - 10, transition: { duration: 0.25 } }}
            >
              <div className="rounded-[16px] bg-white p-1.5 shadow-[0_0_0_1px_rgba(15,18,24,0.06),0_20px_40px_-18px_rgba(15,18,24,0.3)]">
                <MediaFrame slot={c.slot} variant="card" className="rounded-[11px]" />
              </div>
            </motion.li>
          ))}
        </motion.ul>

        <h2 id="final-cta-title" className="l-h2 mt-16 max-w-[16ch] text-balance">
          {CTA_FINAL.title} <span className="l-title-muted">{CTA_FINAL.titleMuted}</span>
        </h2>
        <p className="mt-5 max-w-[44ch] text-pretty text-[17px] leading-relaxed text-[#5D6168]">{CTA_FINAL.body}</p>

        <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
          <ExternalCta
            href={LINKS.macDownload}
            unavailableNoteId="final-download-note"
            unavailableLabel={HERO.downloadUnavailable}
            unavailableBadge={HERO.soon}
            onActivate={(ok) => onCta(ok ? 'final_download' : 'final_download_unavailable')}
            variant="primary"
            tone="light"
            size="lg"
          >
            <Monitor className="-mt-0.5 h-4 w-4" aria-hidden="true" />
            {HERO.download}
          </ExternalCta>
          <LandingLink href={LINKS.guide} variant="secondary" tone="light" size="lg" onClick={() => onCta('final_guide')}>
            {HERO.guide}
          </LandingLink>
          <span id="final-download-note" className="sr-only">
            {HERO.downloadUnavailable}
          </span>
        </div>
      </div>
    </section>
  );
}
