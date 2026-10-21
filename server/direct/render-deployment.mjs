import { readFileSync, mkdirSync, writeFileSync, copyFileSync, chmodSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isIP } from 'node:net';
import { approvedRelayQuote } from './coordinator.mjs';

// Public IPv4 syntax/range policy, not proof of ownership or actual TURN reachability.
// IANA IPv4 Special-Purpose Address Registry (updated 2025-10-09):
// https://www.iana.org/assignments/iana-ipv4-special-registry/
// Reject non-global/terminated allocations; retain globally reachable more-specific
// assignments (192.0.0.9 and .10). The registry does not cover multicast, so also
// reject 224/4; 240/4 includes the limited broadcast /32. No IPv6 policy is implied.
const nonPublicIPv4 = [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
  ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
  ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
].map(([network, prefix]) => [ipv4Number(network), 2 ** (32 - prefix)]);

function ipv4Number(ip) {
  return ip.split('.').reduce((value, octet) => value * 256 + Number(octet), 0);
}

function publicIPv4(ip) {
  if (isIP(ip) !== 4) return false;
  if (ip === '192.0.0.9' || ip === '192.0.0.10') return true;
  const address = ipv4Number(ip);
  return !nonPublicIPv4.some(([network, size]) => address >= network && address < network + size);
}

export function deployment(env, quote) {
  const domain = key => {
    const value = env[key] ?? '';
    if (!/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(value)) throw new Error('invalid_domain');
    return value;
  };
  const coordinator = domain('AIM_DIRECT_COORDINATOR_DOMAIN'), relay = domain('AIM_DIRECT_RELAY_DOMAIN');
  if (coordinator === relay) throw new Error('distinct_domains_required');
  const ip = env.AIM_DIRECT_PUBLIC_IPV4 ?? '';
  if (!publicIPv4(ip)) throw new Error('public_ipv4_required');
  for (const key of ['AIM_DIRECT_TURN_SECRET', 'AIM_DIRECT_ADMIN_TOKEN']) {
    if (!/^[a-f0-9]{64,128}$/i.test(env[key] ?? '')) throw new Error('independent_random_hex_secrets_required');
  }
  if (env.AIM_DIRECT_TURN_SECRET === env.AIM_DIRECT_ADMIN_TOKEN) throw new Error('independent_secrets_required');
  const quota = Number(env.AIM_DIRECT_RELAY_MONTHLY_BYTES ?? 10737418240);
  if (!approvedRelayQuote(quote) || !Number.isSafeInteger(quota) || quota < 0
      || !Number.isSafeInteger(quote.includedTrafficBytes) || quota > quote.includedTrafficBytes) throw new Error('reviewed_fixed_price_quote_required');
  // These limits must agree with coordinator reservations. Changes require both configurations.
  const turn = `listening-port=3478\nlistening-ip=0.0.0.0\nexternal-ip=${ip}\nrealm=${relay}\nserver-name=${relay}\nfingerprint\nuse-auth-secret\nstatic-auth-secret=${env.AIM_DIRECT_TURN_SECRET}\nmin-port=49160\nmax-port=49223\nmax-bps=131072\nbps-capacity=2097152\nuser-quota=2\ntotal-quota=16\nmax-allocate-lifetime=120\nno-tls\nno-dtls\nno-tcp-relay\nno-cli\nno-multicast-peers\ndeny-peer-ip=0.0.0.0-0.255.255.255\ndeny-peer-ip=10.0.0.0-10.255.255.255\ndeny-peer-ip=127.0.0.0-127.255.255.255\ndeny-peer-ip=169.254.0.0-169.254.255.255\ndeny-peer-ip=172.16.0.0-172.31.255.255\ndeny-peer-ip=192.168.0.0-192.168.255.255\ndeny-peer-ip=224.0.0.0-255.255.255.255\ndeny-peer-ip=::1\ndeny-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff\ndeny-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff\nlog-file=stdout\nlog-min-level=warning\npidfile=/tmp/turnserver.pid\n`;
  const proxy = `global\n  maxconn 512\n  ssl-default-bind-options ssl-min-ver TLSv1.2\ndefaults\n  mode tcp\n  timeout connect 5s\n  timeout client 10m\n  timeout server 10m\nfrontend encrypted\n  bind :8443 ssl crt /config/tls.pem\n  use_backend turn if { ssl_fc_sni -i ${relay} }\n  use_backend coordinator if { ssl_fc_sni -i ${coordinator} }\n  tcp-request content reject if !{ ssl_fc_sni -i ${relay} ${coordinator} }\nbackend coordinator\n  server node coordinator:8789 check\nbackend turn\n  server relay turn:3478 check\n`;
  const coordinatorEnv = `AIM_DIRECT_BIND=0.0.0.0\nAIM_DIRECT_STATE=/data/coordinator.json\nAIM_DIRECT_HOSTING_QUOTE=/config/hosting-quote.json\nAIM_DIRECT_ADMIN_TOKEN=${env.AIM_DIRECT_ADMIN_TOKEN}\nAIM_DIRECT_TURN_SECRET=${env.AIM_DIRECT_TURN_SECRET}\nAIM_DIRECT_TURN_URLS=stun:${relay}:3478,turns:${relay}:443?transport=tcp\nAIM_DIRECT_TURN_TTL=120\nAIM_DIRECT_TURN_BPS=131072\nAIM_DIRECT_TURN_USER_QUOTA=2\nAIM_DIRECT_RELAY_MONTHLY_BYTES=${quota}\n`;
  return { turn, proxy, coordinatorEnv };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const quote = JSON.parse(readFileSync(process.env.AIM_DIRECT_HOSTING_QUOTE, 'utf8'));
  const files = deployment(process.env, quote), target = resolve('.private/deploy');
  const certificate = readFileSync(process.env.AIM_DIRECT_TLS_PEM, 'utf8');
  if (!certificate.includes('BEGIN CERTIFICATE') || !/BEGIN (?:RSA |EC )?PRIVATE KEY/.test(certificate)) throw new Error('certificate_and_private_key_required');
  mkdirSync(target, { recursive: true, mode: 0o700 });
  mkdirSync(target + '/state', { recursive: true, mode: 0o700 });
  for (const [name, data] of Object.entries({ 'turnserver.conf': files.turn, 'haproxy.cfg': files.proxy,
    'compose.env': `AIM_DIRECT_RUNTIME_UID=${process.getuid()}\nAIM_DIRECT_RUNTIME_GID=${process.getgid()}\n`,
    'coordinator.env': files.coordinatorEnv, 'hosting-quote.json': JSON.stringify(quote, null, 2) + '\n' })) {
    writeFileSync(target + '/' + name, data, { mode: 0o600 }); chmodSync(target + '/' + name, 0o600);
  }
  copyFileSync(process.env.AIM_DIRECT_TLS_PEM, target + '/tls.pem'); chmodSync(target + '/tls.pem', 0o600);
  process.stdout.write('Private configuration generated. Validate containers, certificate, firewall and state ownership before starting.\n');
}
