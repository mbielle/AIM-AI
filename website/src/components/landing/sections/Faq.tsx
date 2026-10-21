import * as Accordion from '@radix-ui/react-accordion';
import { Plus } from 'lucide-react';
import { FAQ, LINKS } from '../content';
import { Reveal } from '../ui/Reveal';

/**
 * A quiet accordion with hairline separators. On wide screens the title column stays in view
 * while the questions scroll past, then leaves with the bottom of the section (sticky inside the
 * section's grid — never fixed to the page, no inner scroll area).
 */
export function Faq() {
  return (
    <section id="faq" aria-labelledby="faq-title" className="relative scroll-mt-[var(--l-nav)] px-4 pb-28 sm:px-8 sm:pb-36">
      <div className="mx-auto grid w-full max-w-[1240px] gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)] lg:gap-16">
        <div className="lg:sticky lg:top-[calc(var(--l-nav)+40px)] lg:self-start">
          <Reveal>
            <h2 id="faq-title" className="l-h2 text-[#0B0B0C]">
              {FAQ.title}
            </h2>
            <p className="mt-5 max-w-[36ch] text-[16px] leading-relaxed text-[#5D6168]">
              {FAQ.contactLead}{' '}
              <a href={LINKS.contact} className="text-[#0B0B0C] underline decoration-black/25 underline-offset-4 transition-colors hover:decoration-black">
                {FAQ.contactLink}
              </a>{' '}
              {FAQ.contactTail}
            </p>
          </Reveal>
        </div>
        <Reveal delay={0.04}>
          <Accordion.Root type="multiple" className="border-t border-black/[0.08]">
            {FAQ.items.map((item, i) => (
              <Accordion.Item key={item.q} value={`q${i}`} className="border-b border-black/[0.08]">
                <Accordion.Header asChild>
                  <h3>
                    <Accordion.Trigger className="group flex w-full items-center justify-between gap-6 py-6 text-left text-[17px] font-medium tracking-[-0.01em] text-[#0B0B0C]">
                      {item.q}
                      <span className="grid h-7 w-7 shrink-0 place-items-center rounded-full shadow-[inset_0_0_0_1px_rgba(11,11,12,0.14)] transition-colors group-hover:bg-black/[0.04]">
                        <Plus
                          className="h-3.5 w-3.5 text-[#34373C] transition-transform duration-300 group-data-[state=open]:rotate-45"
                          strokeWidth={1.9}
                          aria-hidden="true"
                        />
                      </span>
                    </Accordion.Trigger>
                  </h3>
                </Accordion.Header>
                <Accordion.Content className="overflow-hidden data-[state=closed]:animate-accordion-up data-[state=open]:animate-accordion-down">
                  <p className="max-w-[62ch] pb-6 text-[16px] leading-relaxed text-[#5D6168]">{item.a}</p>
                </Accordion.Content>
              </Accordion.Item>
            ))}
          </Accordion.Root>
        </Reveal>
      </div>
    </section>
  );
}
