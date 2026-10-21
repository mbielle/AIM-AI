import type { ReactNode } from 'react';
import { FOOTER, HERO, LINKS } from '../content';
import { SupportLink } from '../ui/SupportLink';
import { DotWordmark } from '../ui/DotWordmark';
import { ExternalCta } from '../ui/ExternalCta';
import { SiteWordmark } from '../ui/SiteWordmark';
import { SocialLinks } from '../ui/SocialLinks';

interface LandingFooterProps {
  /** Optional control shown on the right of the bottom row (e.g. the language switch on legal pages). */
  aside?: ReactNode;
}

const linkClass = 'text-[15px] text-[#5D6168] transition-colors hover:text-[#0B0B0C]';

/**
 * Site footer: brand block and download on the left, link groups on the right, then copyright and
 * privacy choices — and the large dotted “AIM” to close the page.
 */
export function LandingFooter({ aside }: LandingFooterProps) {
  return (
    <footer className="relative overflow-hidden px-5 pt-20 sm:px-8 lg:px-10" aria-labelledby="footer-title">
      <h2 id="footer-title" className="sr-only">
        Site links
      </h2>
      <div className="mx-auto w-full max-w-[1240px]">
        <div className="grid gap-14 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)]">
          <div>
            <a href="/" className="inline-grid h-12 w-12 place-items-center rounded-full bg-white/90 text-[#0B0B0C] shadow-[0_0_0_1px_rgba(15,18,24,0.06),0_8px_24px_-10px_rgba(15,18,24,0.18)]" aria-label="AIM — home">
              <SiteWordmark size={26} tone="light" markOnly />
            </a>
            <p className="mt-5 text-[15px] text-[#5D6168]">{FOOTER.tagline}</p>
            <ExternalCta
              href={LINKS.macDownload}
              unavailableNoteId="footer-download-note"
              unavailableLabel={HERO.downloadUnavailable}
              unavailableBadge={HERO.soon}
              variant="primary"
              tone="light"
              size="md"
              className="mt-7 h-11"
            >
              {HERO.download}
            </ExternalCta>
            <span id="footer-download-note" className="sr-only">
              {HERO.downloadUnavailable}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-x-8 gap-y-12 sm:grid-cols-4">
            {FOOTER.columns.map((col) => (
              <nav key={col.title} aria-label={col.title}>
                <p className="mb-5 text-[14px] font-medium text-[#0B0B0C]">{col.title}</p>
                {'social' in col && <SocialLinks className="mb-4 flex-col items-start gap-y-4" itemClassName={linkClass} />}
                <ul className="space-y-4">
                  {col.links &&
                    col.links.map((l) => (
                      <li key={l.label}>
                        <a href={l.href} className={linkClass}>
                          {l.label}
                        </a>
                      </li>
                    ))}
                  {col.downloads &&
                    col.downloads.map((d) => {
                      const href = LINKS[d.key];
                      return (
                        <li key={d.label}>
                          {href ? (
                            <a href={href} className={linkClass}>
                              {d.label}
                            </a>
                          ) : (
                            <span className="inline-flex items-center gap-2 text-[15px] text-[#8E939B]">
                              {d.label}
                              <span className="rounded-full bg-black/[0.06] px-2 py-[3px] text-[11.5px] font-medium leading-none text-black/55">{FOOTER.soon}</span>
                            </span>
                          )}
                        </li>
                      );
                    })}
                </ul>
              </nav>
            ))}
          </div>
        </div>

        <div className="mt-20 flex flex-col gap-4 text-[13.5px] text-[#6B6F76] sm:flex-row sm:items-center sm:justify-between">
          <span>{FOOTER.copyright}</span>
          <div className="flex flex-wrap items-center gap-x-6 gap-y-3">
            <SupportLink />
            {aside}
          </div>
        </div>
      </div>

      <DotWordmark className="mx-auto mt-12 block w-[min(1100px,100%)]" />
    </footer>
  );
}
