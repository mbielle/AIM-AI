import type { ReactNode } from 'react';
import { LandingNav } from './components/landing/sections/LandingNav';
import { LandingFooter } from './components/landing/sections/LandingFooter';
import './components/landing/styles.css';
export function InformationPage({ title, children }: { title: string; children: ReactNode }) {
  return <div className="aim-landing min-h-screen"><LandingNav onCta={() => {}} /><main className="l-legal mx-auto max-w-3xl px-6 pb-24 pt-36"><h1 className="l-h2 mb-10">{title}</h1>{children}</main><LandingFooter /></div>;
}
