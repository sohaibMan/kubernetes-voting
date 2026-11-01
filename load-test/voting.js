import http from 'k6/http';
import { check, sleep } from 'k6';

const base = (__ENV.BASE_URL || 'http://voting-app.voting.svc.cluster.local').replace(/\/$/, '');
const peak = Number(__ENV.PEAK_VUS || 50);
if (!Number.isInteger(peak) || peak < 1 || peak > 500) {
  throw new Error('PEAK_VUS must be an integer between 1 and 500');
}
export const options = {
  stages: [
    { duration: '30s', target: Math.min(10, peak) },
    { duration: '30s', target: Math.min(25, peak) },
    { duration: '30s', target: peak },
    { duration: '1m', target: peak },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
    checks: ['rate>0.99'],
  },
  // New connections let the Service distribute traffic across app replicas.
  noConnectionReuse: true,
};
function valid(response) {
  if (response.status !== 200) return false;
  try {
    const data = response.json();
    return typeof data.votes.cats === 'number' && typeof data.votes.dogs === 'number';
  } catch (_) { return false; }
}
export function setup() {
  const response = http.get(`${base}/readyz`, { timeout: '5s' });
  if (response.status !== 200) throw new Error('App is not ready: ' + response.status);
}
export default function () {
  const choice = Math.random() < 0.5 ? 'cats' : 'dogs';
  const vote = http.post(`${base}/api/vote`, JSON.stringify({ choice }), {
    headers: { 'Content-Type': 'application/json' }, timeout: '5s', tags: { endpoint: 'vote' },
  });
  check(vote, { 'vote accepted with totals': valid });
  const result = http.get(`${base}/api/results`, { timeout: '5s', tags: { endpoint: 'results' } });
  check(result, { 'results returned': valid });
  sleep(1);
}
