import { ChevronDown, Code2, Hand, Menu, Plus } from 'lucide-react';

/**
 * AIM on iPhone — the Remote session list, designed at 390 × 844 pt (only the top is shown on the
 * page). Header layout follows RemoteMobileHeader (leading menu, centred mode title, trailing
 * action); the device filter follows RemoteMachineFilter. Content is fictional.
 */
function AgentGlyph({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 17" fill="none" stroke="currentColor" className={className} aria-hidden="true">
      <rect x="1.5" y="6" width="13" height="10" rx="3" strokeWidth="1.3" />
      <path d="M8 3v3" strokeWidth="1.3" />
      <circle cx="8" cy="2" r="1.3" fill="currentColor" stroke="none" />
      <circle cx="6" cy="11" r="1.05" fill="currentColor" stroke="none" />
      <circle cx="10" cy="11" r="1.05" fill="currentColor" stroke="none" />
    </svg>
  );
}

const SESSIONS = [
  { title: 'Fix login redirect loop', meta: 'Waiting for your approval', running: true },
  { title: 'Add tests for the release service', meta: 'Code · Done · 12 min ago' },
  { title: 'Summarize this week’s support tickets', meta: 'Agent · Done · 1 h ago', agent: true },
  { title: 'Update the API reference', meta: 'Code · Done · Yesterday' },
];

export function PhoneRemoteScreen() {
  return (
    <div className="relative h-full w-full bg-white text-[#171717]" style={{ fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif' }}>
      {/* Status bar and Dynamic Island */}
      <div className="relative h-[54px]">
        <span className="absolute left-[50px] top-[16px] text-[17px] font-semibold tracking-[-0.01em]">9:41</span>
        <span className="absolute left-1/2 top-[11px] h-[36px] w-[124px] -translate-x-1/2 rounded-full bg-black" aria-hidden="true" />
        <span className="absolute right-[30px] top-[21px] flex items-center gap-[6px]" aria-hidden="true">
          <span className="flex items-end gap-[2px]">
            {[4, 6, 8, 10].map((h) => (
              <span key={h} className="w-[3px] rounded-[1px] bg-[#171717]" style={{ height: h }} />
            ))}
          </span>
          <svg width="16" height="12" viewBox="0 0 16 12" fill="#171717">
            <path d="M8 2.2c2.3 0 4.4.9 6 2.4l1.1-1.2A10 10 0 0 0 8 .6 10 10 0 0 0 .9 3.4L2 4.6a8.4 8.4 0 0 1 6-2.4Zm0 3.3c1.4 0 2.7.5 3.7 1.4l1.1-1.2A7 7 0 0 0 8 3.9a7 7 0 0 0-4.8 1.8l1.1 1.2c1-.9 2.3-1.4 3.7-1.4Zm0 3.3c.6 0 1.1.2 1.5.6L8 11 6.5 9.4c.4-.4.9-.6 1.5-.6Z" />
          </svg>
          <span className="ml-[2px] h-[12px] w-[25px] rounded-[4px] border border-black/35 p-[1.5px]">
            <span className="block h-full w-[78%] rounded-[2px] bg-[#171717]" />
          </span>
        </span>
      </div>

      {/* Header: menu, mode title, new session */}
      <header className="grid grid-cols-[44px_minmax(0,1fr)_44px] items-center px-4 pt-2">
        <span className="grid h-11 w-11 place-items-center rounded-full bg-[#F2F2F4]">
          <Menu className="h-[19px] w-[19px]" strokeWidth={1.9} />
        </span>
        <p className="text-center text-[19px] font-semibold tracking-[-0.01em]">Code</p>
        <span className="grid h-11 w-11 place-items-center rounded-full bg-[#F2F2F4]">
          <Plus className="h-[19px] w-[19px]" strokeWidth={1.9} />
        </span>
      </header>

      {/* Device filter */}
      <div className="px-5 pt-5">
        <span className="inline-flex items-center gap-2 rounded-full bg-[#F2F2F4] px-3.5 py-[7px] text-[15px] font-medium">
          <span className="h-2 w-2 rounded-full bg-[#34C759]" aria-hidden="true" />
          MacBook Pro
          <ChevronDown className="h-3.5 w-3.5 text-black/45" strokeWidth={2} />
        </span>
      </div>

      {/* Sessions */}
      <p className="px-5 pb-2 pt-6 text-[15px] font-semibold text-black/45">Sessions</p>
      <ul className="px-3">
        {SESSIONS.map((s) => (
          <li key={s.title} className={`flex items-center gap-3 rounded-[16px] px-3 py-3 ${s.running ? 'bg-[#F4F4F6]' : ''}`}>
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-white text-black/55 shadow-[0_0_0_1px_rgba(0,0,0,0.07)]">
              {s.running ? (
                <Hand className="h-[17px] w-[17px] text-[#171717]" strokeWidth={1.8} />
              ) : s.agent ? (
                <AgentGlyph className="h-[17px] w-4" />
              ) : (
                <Code2 className="h-[17px] w-[17px]" strokeWidth={1.8} />
              )}
            </span>
            <span className="min-w-0">
              <span className="block truncate text-[16px] font-medium">{s.title}</span>
              <span className="block truncate text-[13.5px] text-black/50">{s.meta}</span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default PhoneRemoteScreen;
