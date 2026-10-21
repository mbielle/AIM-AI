import type { ReactNode } from 'react';
import { motion, useReducedMotion } from 'motion/react';

interface RevealProps {
  children: ReactNode;
  className?: string;
  delay?: number;
  /** Distance travelled while fading in, px. */
  y?: number;
}

/** Gentle fade-and-rise on first entry into view. Static with reduced motion. */
export function Reveal({ children, className, delay = 0, y = 24 }: RevealProps) {
  const reduced = useReducedMotion();
  if (reduced) return <div className={className}>{children}</div>;
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '0px 0px -12% 0px' }}
      transition={{ duration: 0.9, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  );
}
