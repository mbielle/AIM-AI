import { cn } from "@/lib/utils";
import { SOCIAL } from "../content";

/** Only configured public project links appear. */
export function SocialLinks({
  className,
  itemClassName,
}: {
  className?: string;
  itemClassName?: string;
}) {
  if (!SOCIAL.length) return null;
  return (
    <ul className={cn("flex flex-wrap items-center", className)}>
      {SOCIAL.map((link) => (
        <li key={link.label}>
          <a
            href={link.href}
            target="_blank"
            rel="noopener noreferrer"
            className={itemClassName}
          >
            {link.label}
          </a>
        </li>
      ))}
    </ul>
  );
}
