/** Values are public build-time settings, never credentials. No release is enabled by default. */
export function externalHttpsUrl(value) {
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const u = new URL(value);
    if (
      u.protocol !== "https:" ||
      u.username ||
      u.password ||
      (u.port && u.port !== "443")
    )
      return null;
    return u.href;
  } catch {
    return null;
  }
}
/** Explicit repository destination; local, placeholder and credential-bearing URLs stay hidden. */
export function sourceRepositoryUrl(value) {
  const accepted = externalHttpsUrl(value);
  if (!accepted) return null;
  const url = new URL(accepted),
    host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (
    !host.includes(".") ||
    host.startsWith("[") ||
    /^[0-9.]+$/.test(host) ||
    /(?:^|\.)(?:localhost|localdomain)(?:\.|$)/.test(host) ||
    /(?:^|\.)(?:localhost|local|invalid|test|example)$/.test(host) ||
    /(?:^|\.)example\.(?:com|org|net)$/.test(host) ||
    url.search ||
    url.hash
  )
    return null;
  let segments;
  try {
    segments = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    return null;
  }
  if (
    !segments.length ||
    (["github.com", "gitlab.com", "codeberg.org", "bitbucket.org"].includes(
      host,
    ) &&
      segments.length < 2) ||
    segments.some((segment) =>
      /^(?:example|owner|your-org|your-user|username|your-repo)$/i.test(
        segment,
      ),
    )
  )
    return null;
  return url.href;
}
export function publicLinks(config = {}) {
  const macPath =
    typeof config.macPath === "string" &&
    /^\/downloads\/[A-Za-z0-9._-]+\.dmg$/.test(config.macPath)
      ? config.macPath
      : null;
  const qualified =
    config.releaseApproved === "true" &&
    /^[a-f0-9]{64}$/.test(config.macSha256 ?? "");
  return {
    macDownload: qualified ? macPath : null,
    iphone: null,
    supportUrl: externalHttpsUrl(config.supportUrl),
    sourceUrl: sourceRepositoryUrl(config.sourceUrl),
  };
}
