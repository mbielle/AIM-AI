import { useRef } from 'react';
import { Hero } from './hero/Hero';
import { LandingNav } from './sections/LandingNav';
import { ProductStory } from './sections/ProductStory';
import { Features } from './sections/Features';
import { UseCases } from './sections/UseCases';
import { Pricing } from './sections/Pricing';
import { FinalCta } from './sections/FinalCta';
import { Faq } from './sections/Faq';
import { LandingFooter } from './sections/LandingFooter';
import { useLandingTracking } from './useLandingTracking';
import './styles.css';

/**
 * AIM landing page (v4). Self-contained: no router, auth or app providers, so it can be rendered
 * on its own while the rest of the web app is in maintenance.
 */
export function LandingPage() {
  const heroRef = useRef<HTMLElement>(null);
  const track = useLandingTracking();

  return (
    <div className="aim-landing min-h-screen" id="top">
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[60] focus:rounded-full focus:bg-white focus:px-4 focus:py-2 focus:text-[14px] focus:text-black"
      >
        Skip to content
      </a>
      <div aria-hidden="true" className="l-grain" />
      <LandingNav heroRef={heroRef} onCta={track} />
      <main id="main">
        <Hero heroRef={heroRef} onCta={track} />
        <ProductStory />
        <Features />
        <UseCases />
        <Pricing onCta={track} />
        <Faq />
        <FinalCta onCta={track} />
      </main>
      <LandingFooter />
    </div>
  );
}

export default LandingPage;
