import { Check } from 'lucide-react';
import { HERO, LINKS, PRICING } from '../content';
import { ExternalCta } from '../ui/ExternalCta';
import { Reveal } from '../ui/Reveal';
import { SupportLink } from '../ui/SupportLink';
export function Pricing({ onCta }: { onCta: (name: string) => void }) {
  return <section id="pricing" aria-labelledby="pricing-title" className="relative scroll-mt-[var(--l-nav)] px-5 pb-28 sm:px-8">
    <div className="mx-auto flex max-w-[1240px] flex-col items-center text-center">
      <Reveal><h2 id="pricing-title" className="l-h2">{PRICING.title}</h2><p className="mx-auto mt-5 max-w-[48ch] text-[17px] text-[#5D6168]">{PRICING.intro}</p></Reveal>
      <Reveal className="mt-10 w-full max-w-[500px]"><div className="l-surface rounded-[24px] p-8 text-left">
        <h3 className="text-lg font-semibold">{PRICING.plan}</h3><p className="mt-5 text-5xl font-semibold">{PRICING.price}</p>
        <ul className="mt-7 space-y-3">{PRICING.includes.map(line => <li key={line} className="flex gap-3 text-[15px]"><Check className="h-5 w-5 shrink-0" aria-hidden="true" />{line}</li>)}</ul>
        <ExternalCta href={LINKS.macDownload} unavailableNoteId="pricing-download-note" unavailableLabel={HERO.downloadUnavailable} unavailableBadge={HERO.soon} onActivate={ok => onCta(ok ? 'pricing_download' : 'pricing_download_unavailable')} variant="primary" tone="light" size="lg" className="mt-8 w-full">{HERO.download}</ExternalCta>
        <span id="pricing-download-note" className="sr-only">{HERO.downloadUnavailable}</span>
        <p className="mt-6 text-sm leading-relaxed text-[#5D6168]">{PRICING.providerNote}</p><p className="mt-4 text-sm leading-relaxed text-[#5D6168]">{PRICING.remoteNote}</p>
        <div className="mt-5 text-sm underline"><SupportLink /></div>
      </div></Reveal>
    </div>
  </section>;
}
