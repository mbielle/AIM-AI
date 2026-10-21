/** Operator configuration only. Client-facing API URLs still require HTTPS.
 * An explicit private-network override supports self-hosted Edge -> gateway hops.
 */
export function backendOrigin(env: (name: string) => string | undefined): URL {
  const internal = env('AIM_INTERNAL_SUPABASE_ORIGIN');
  let url: URL;
  try { url = new URL(internal ?? env('SUPABASE_URL') ?? ''); }
  catch { throw new Error('server_not_configured'); }
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
      (url.port && !(Number(url.port) >= 1 && Number(url.port) <= 65535))) {
    throw new Error('server_not_configured');
  }
  if (url.protocol === 'https:') return url;
  const host = url.hostname;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  const octets = v4?.slice(1).map(Number);
  const privateIP = octets?.every(n => n <= 255) &&
    (octets[0] === 127 || octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168));
  const privateHost = privateIP || host === '[::1]' || host === 'localhost' ||
    host === 'host.docker.internal' || (!v4 && /^[a-z][a-z0-9-]*$/i.test(host));
  if (internal && env('AIM_INTERNAL_SUPABASE_ALLOW_HTTP') === 'true' &&
      url.protocol === 'http:' && privateHost) return url;
  throw new Error('server_not_configured');
}
