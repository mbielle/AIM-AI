import { useState } from 'react';
import { InformationPage } from './InformationPage';
export function UnsubscribePage() {
  const token = new URLSearchParams(window.location.search).get('token') ?? '';
  const [state, setState] = useState<'ready' | 'pending' | 'success' | 'already' | 'error'>('ready');
  async function confirm() {
    if (!token || state === 'pending') return;
    setState('pending');
    try {
      const response = await fetch('/api/unsubscribe', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token }), credentials: 'omit', referrerPolicy: 'no-referrer' });
      const result = await response.json();
      setState(response.ok && result.success === true ? 'success' : result.reason === 'already_unsubscribed' ? 'already' : 'error');
    } catch { setState('error'); }
  }
  return <InformationPage title="Unsubscribe from AIM emails"><section><p>Confirm removal from non-essential AIM emails. Monitoring links also cover AIM alerts. Essential account messages may still be sent.</p>
    {!token ? <p role="alert">This link is missing its token. Use the link in your email or contact <a href="mailto:contact@aim-ai.tech">contact@aim-ai.tech</a>.</p> : state === 'success' || state === 'already' ? <p role="status">Your unsubscribe preference is recorded.</p> : <><button className="my-6 rounded-full bg-black px-6 py-3 text-white" disabled={state === 'pending'} onClick={confirm}>{state === 'pending' ? 'Processing…' : 'Confirm unsubscribe'}</button>{state === 'error' && <p role="alert">The request could not be completed. Try again later or contact <a href="mailto:contact@aim-ai.tech">contact@aim-ai.tech</a>.</p>}</>}
  </section></InformationPage>;
}
