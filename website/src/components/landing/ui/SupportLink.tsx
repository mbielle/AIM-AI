import { supportUrl } from '../releaseLinks';
/** Optional external support. No payment is collected or tracked here. */
export function SupportLink() {
  return supportUrl ? <a href={supportUrl} rel="noopener noreferrer" target="_blank">Support AIM (optional)</a> : null;
}
