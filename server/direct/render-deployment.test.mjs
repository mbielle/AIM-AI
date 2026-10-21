import test from 'node:test';
import assert from 'node:assert/strict';
import { deployment } from './render-deployment.mjs';
const env = { AIM_DIRECT_COORDINATOR_DOMAIN: 'connect.example.org', AIM_DIRECT_RELAY_DOMAIN: 'relay.example.org',
  // Public witness used only to generate strings in memory; no connection is opened.
  AIM_DIRECT_PUBLIC_IPV4: '8.8.8.8', AIM_DIRECT_TURN_SECRET: '1'.repeat(64), AIM_DIRECT_ADMIN_TOKEN: '2'.repeat(64) };
const quote = { currency: 'EUR', monthlyTotalEUR: 12, billableOverage: false, automaticTopUps: false,
  reviewedBy: 'synthetic-test', validUntil: '2099-01-01', includedTrafficBytes: 10737418240 };
test('coordinator and TURN limits agree; no anonymous or local-network relay', () => {
  const config = deployment(env, quote);
  assert.match(config.turn, /use-auth-secret\n/); assert.match(config.turn, /max-allocate-lifetime=120\n/);
  assert.match(config.coordinatorEnv, /AIM_DIRECT_TURN_TTL=120\n/);
  assert.match(config.turn, /user-quota=2\n/); assert.match(config.coordinatorEnv, /AIM_DIRECT_TURN_USER_QUOTA=2\n/);
  assert.doesNotMatch(config.turn, /allow-loopback|no-auth|server-relay/);
  assert.match(config.proxy, /ssl-min-ver TLSv1.2/); assert.match(config.coordinatorEnv, /turns:relay.example.org:443/);
});
test('refuse unreviewed cost, paid overage, insufficient included traffic and config injection', () => {
  for (const change of [{ monthlyTotalEUR: 21 }, { billableOverage: true }, { reviewedBy: '' }, { includedTrafficBytes: 1 }])
    assert.throws(() => deployment(env, { ...quote, ...change }));
  for (const change of [{ AIM_DIRECT_PUBLIC_IPV4: '127.0.0.1' }, { AIM_DIRECT_RELAY_DOMAIN: 'example.org\nno-auth' },
    { AIM_DIRECT_TURN_SECRET: env.AIM_DIRECT_ADMIN_TOKEN }, { AIM_DIRECT_ADMIN_TOKEN: 'short' }])
    assert.throws(() => deployment({ ...env, ...change }, quote));
});

for (const ip of ['224.0.0.1', '239.255.255.250', '255.255.255.255', '100.64.0.1', '198.18.0.1']) {
  test(`refuse established non-public TURN address ${ip}`, () => {
    assert.throws(() => deployment({ ...env, AIM_DIRECT_PUBLIC_IPV4: ip }, quote), /public_ipv4_required/);
  });
}

test('reject special-purpose IPv4 ranges at both boundaries and invalid inputs', async t => {
  const rejected = [
    ['0.0.0.0', '0.255.255.255'], ['10.0.0.0', '10.255.255.255'],
    ['100.64.0.0', '100.127.255.255'], ['127.0.0.0', '127.255.255.255'],
    ['169.254.0.0', '169.254.255.255'], ['172.16.0.0', '172.31.255.255'],
    ['192.0.0.0', '192.0.0.255'], ['192.0.2.0', '192.0.2.255'],
    ['192.88.99.0', '192.88.99.255'], ['192.168.0.0', '192.168.255.255'],
    ['198.18.0.0', '198.19.255.255'], ['198.51.100.0', '198.51.100.255'],
    ['203.0.113.0', '203.0.113.255'], ['224.0.0.0', '239.255.255.255'],
    ['240.0.0.0', '255.255.255.255'],
  ].flat().concat(['192.0.0.7', '192.0.0.8', '192.0.0.11', '192.0.0.170', '192.0.0.171',
    '192.88.99.2', '203.0.113.1', '', '1.2.3', '256.1.2.3', '01.2.3.4', '1.2.3.4\n',
    ' 8.8.8.8', '8.8.8.8/32', '8.8.8.8:3478', '::1', '::ffff:8.8.8.8']);
  for (const ip of rejected) await t.test(JSON.stringify(ip), () => {
    assert.throws(() => deployment({ ...env, AIM_DIRECT_PUBLIC_IPV4: ip }, quote), /public_ipv4_required/);
  });
});

test('accept public neighbours and globally reachable more-specific IANA assignments in memory', async t => {
  for (const ip of ['1.0.0.0', '9.255.255.255', '11.0.0.0', '100.63.255.255', '100.128.0.0',
    '126.255.255.255', '128.0.0.0', '169.253.255.255', '169.255.0.0', '172.15.255.255', '172.32.0.0',
    '192.0.0.9', '192.0.0.10', '192.0.1.0', '192.0.1.255', '192.0.3.0',
    '192.31.196.1', '192.52.193.1', '192.88.98.255', '192.88.100.0',
    '192.167.255.255', '192.169.0.0', '192.175.48.1', '198.17.255.255', '198.20.0.0',
    '198.51.99.255', '198.51.101.0', '203.0.112.255', '203.0.114.0', '223.255.255.255']) {
    await t.test(ip, () => {
      assert.match(deployment({ ...env, AIM_DIRECT_PUBLIC_IPV4: ip }, quote).turn, new RegExp(`external-ip=${ip.replaceAll('.', '\\.')}\\n`));
    });
  }
});
