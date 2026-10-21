import { USE_CASES } from '../content';
import { MediaFrame } from '../media/MediaFrame';
import { Reveal } from '../ui/Reveal';
import type { MediaSlotId } from '../media';

/** One situation per card: its media on top (plays while visible), category and promise below. */
function UseCaseCard({ category, title, media, wide = false }: { category: string; title: string; media: MediaSlotId; wide?: boolean }) {
  return (
    <article className={`l-surface h-full overflow-hidden rounded-[24px] ${wide ? 'grid items-end md:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)]' : 'flex flex-col'}`}>
      <div className="p-2.5">
        <MediaFrame slot={media} variant="card" className="rounded-[16px]" />
      </div>
      <div className={wide ? 'px-7 pb-7 pt-4 md:pb-9 md:pl-6 md:pr-9' : 'px-7 pb-7 pt-4'}>
        <p className="text-[13px] text-[#8E939B]">{category}</p>
        <h3 className="mt-2 text-balance text-[22px] font-medium leading-[1.25] tracking-[-0.025em] text-[#0B0B0C]">{title}</h3>
      </div>
    </article>
  );
}

/** Situations rather than features: what a working day with AIM looks like. */
export function UseCases() {
  return (
    <section id="use-cases" aria-labelledby="use-cases-title" className="relative scroll-mt-[var(--l-nav)] px-4 pb-28 sm:px-8 sm:pb-36">
      <div className="mx-auto w-full max-w-[1240px]">
        <Reveal className="max-w-[760px]">
          <h2 id="use-cases-title" className="l-h2 text-balance">
            {USE_CASES.title}
          </h2>
          <p className="l-title-muted mt-5 max-w-[56ch] text-pretty text-[19px] leading-relaxed">{USE_CASES.intro}</p>
        </Reveal>

        <ul className="mt-14 grid gap-5 sm:mt-16 md:grid-cols-2">
          {USE_CASES.items.map((item, i) => (
            <li key={item.media}>
              <Reveal delay={(i % 2) * 0.06} y={28} className="h-full">
                <UseCaseCard {...item} />
              </Reveal>
            </li>
          ))}
          <li className="md:col-span-2">
            <Reveal y={28}>
              <UseCaseCard {...USE_CASES.wide} wide />
            </Reveal>
          </li>
        </ul>
      </div>
    </section>
  );
}
