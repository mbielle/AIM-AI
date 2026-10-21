import { forwardRef, type AnchorHTMLAttributes, type ButtonHTMLAttributes } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '@/lib/utils';

export const landingButton = cva(
  'inline-flex select-none items-center justify-center gap-2 whitespace-nowrap rounded-full font-medium tracking-[-0.01em] transition-[background-color,box-shadow,color,transform] duration-200 ease-out active:scale-[0.98] aria-disabled:cursor-default aria-disabled:active:scale-100',
  {
    variants: {
      variant: { primary: '', secondary: '', ghost: '' },
      tone: { dark: '', light: '' },
      size: {
        sm: 'h-9 px-4 text-[13.5px]',
        md: 'h-10 px-[18px] text-[14px]',
        lg: 'h-12 px-6 text-[15px]',
        xl: 'h-[52px] px-7 text-[16px]',
      },
    },
    compoundVariants: [
      { variant: 'primary', tone: 'dark', className: 'bg-[#F2F3F5] text-[#0B0B0C] hover:bg-white aria-disabled:bg-[#E4E6EA] aria-disabled:hover:bg-[#E4E6EA]' },
      { variant: 'primary', tone: 'light', className: 'bg-[#0B0B0C] text-white hover:bg-[#25272B] aria-disabled:bg-[#2A2C30] aria-disabled:hover:bg-[#2A2C30]' },
      { variant: 'secondary', tone: 'dark', className: 'text-[#E8EAED] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.16)] hover:bg-white/[0.06]' },
      { variant: 'secondary', tone: 'light', className: 'text-[#0B0B0C] shadow-[inset_0_0_0_1px_rgba(11,11,12,0.14)] hover:bg-[#0B0B0C]/[0.04]' },
      { variant: 'ghost', tone: 'dark', className: 'text-[#C9CDD3] hover:text-white' },
      { variant: 'ghost', tone: 'light', className: 'text-[#34373C] hover:text-[#0B0B0C]' },
    ],
    defaultVariants: { variant: 'primary', tone: 'dark', size: 'md' },
  },
);

export type LandingButtonVariants = VariantProps<typeof landingButton>;

export const LandingLink = forwardRef<HTMLAnchorElement, AnchorHTMLAttributes<HTMLAnchorElement> & LandingButtonVariants>(
  ({ className, variant, tone, size, ...props }, ref) => (
    <a ref={ref} className={cn(landingButton({ variant, tone, size }), className)} {...props} />
  ),
);
LandingLink.displayName = 'LandingLink';

export const LandingButton = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & LandingButtonVariants>(
  ({ className, variant, tone, size, type = 'button', ...props }, ref) => (
    <button ref={ref} type={type} className={cn(landingButton({ variant, tone, size }), className)} {...props} />
  ),
);
LandingButton.displayName = 'LandingButton';
