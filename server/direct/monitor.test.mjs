import test from 'node:test';
import assert from 'node:assert/strict';
import { alerts } from './monitor.mjs';
test('relay reservation thresholds remain distinct from actual charges', () => {
  const metrics = { stateHealthy: true, relayEnabled: true, relayMonthlyBytes: 100, relayReservedBytes: 74 };
  assert.deepEqual(alerts(metrics), []);
  assert.deepEqual(alerts({ ...metrics, relayReservedBytes: 75 }), ['relay_reservations_75_percent']);
  assert.deepEqual(alerts({ ...metrics, relayReservedBytes: 90 }), ['relay_reservations_90_percent']);
  assert.deepEqual(alerts({ ...metrics, relayReservedBytes: 100 }), ['relay_reservations_exhausted']);
  assert.deepEqual(alerts({ ...metrics, relayReservedBytes: NaN }), ['metrics_invalid']);
  assert.deepEqual(alerts({ ...metrics, relayEnabled: false, relayMonthlyBytes: 0 }), []);
  assert.deepEqual(alerts({ ...metrics, stateHealthy: false }), ['coordinator_unavailable']);
});
