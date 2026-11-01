import http from 'k6/http';
import { check, sleep } from 'k6';

const base = (__ENV.BASE_URL || 'http://voting-app.voting.svc.cluster.local').replace(/\/$/, '');
const peak = Number(__ENV.PEAK_VUS || 100);
if (!Number.isInteger(peak) || peak < 1 || peak > 500) {
  throw new Error('PEAK_VUS must be an integer between 1 and 500');
}
export const options = {
  stages: [
    { duration: '30s', target: Math.min(10, peak) },
    { duration: '1m', target: Math.min(50, peak) },
    { duration: '1m', target: peak },
    { duration: '3m', target: peak },
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
  let catShare;
  if (__ENV.CAT_SHARE !== undefined) {
    catShare = Number(__ENV.CAT_SHARE);
    if (__ENV.CAT_SHARE.trim() === '' || !Number.isFinite(catShare) || catShare < 0 || catShare > 1) {
      throw new Error('CAT_SHARE must be a number between 0 and 1');
    }
  } else {
    // One shared preference per run, so independent VUs do not cancel each
    // other's preferences back to 50/50. Individual votes remain random.
    const favoriteShare = 0.65 + Math.random() * 0.20;
    catShare = Math.random() < 0.5 ? favoriteShare : 1 - favoriteShare;
  }
  console.log(`This run's preference: cats ${(catShare * 100).toFixed(1)}%, dogs ${((1 - catShare) * 100).toFixed(1)}%`);
  return { catShare };
}
export default function (data) {
  const choice = Math.random() < data.catShare ? 'cats' : 'dogs';
  const vote = http.post(`${base}/api/vote`, JSON.stringify({ choice }), {
    headers: { 'Content-Type': 'application/json' }, timeout: '5s', tags: { endpoint: 'vote' },
  });
  check(vote, { 'vote accepted with totals': valid });
  const result = http.get(`${base}/api/results`, { timeout: '5s', tags: { endpoint: 'results' } });
  check(result, { 'results returned': valid });
  sleep(Number(__ENV.THINK_TIME || 0.1));
}
