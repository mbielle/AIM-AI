import { ArrowUp, ChevronDown, Columns2, Copy, Folder, MessageSquare, PanelLeft, Plus, RotateCcw, Search, SquarePen } from 'lucide-react';
import { TrafficLights } from '../MacWindow';

/**
 * Placeholder for the AIM Mac app, designed at 1200 × 750 and scaled as a whole.
 * Structure and labels follow the real app (AIM-macOS RootView / ChatView / AIMComposer): a top bar
 * on the same gray surface as the sidebar (window controls, sidebar toggle, conversation title,
 * workbench tabs),
 * “Chat ⌄” space switcher, New chat, Projects, Search conversations, Recents with chat/agent
 * icons, profile at the bottom, inset rounded canvas, white composer “Ask anything”.
 * Replace with a real capture through <ProductShot src=…> when available.
 */
export const CHAT_SCREEN_SIZE = { width: 1200, height: 750 };

/** The Mac app's agent-task glyph: a small robot head (ConversationKindIcon). */
function AgentGlyph() {
  return (
    <svg width="16" height="17" viewBox="0 0 16 17" fill="none" stroke="currentColor" aria-hidden="true">
      <rect x="1.5" y="6" width="13" height="10" rx="3" strokeWidth="1.2" />
      <path d="M8 3v3" strokeWidth="1.2" />
      <circle cx="8" cy="2" r="1.25" fill="currentColor" stroke="none" />
      <circle cx="6" cy="11" r="1" fill="currentColor" stroke="none" />
      <circle cx="10" cy="11" r="1" fill="currentColor" stroke="none" />
    </svg>
  );
}

const RECENTS: Array<{ title: string; agent?: boolean; active?: boolean }> = [
  { title: 'Caching strategy for the API', active: true },
  { title: 'Summarize this week’s support tickets', agent: true },
  { title: 'Rewrite the onboarding emails' },
  { title: 'Find flaky tests in the CI logs', agent: true },
  { title: 'Compare vector databases' },
  { title: 'Plan the Lisbon offsite', agent: true },
  { title: 'Explain this SQL query plan' },
  { title: 'Draft release notes for 2.4' },
];

export function ChatScreen() {
  return (
    <div className="flex h-full w-full flex-col bg-[#F3F3F3] text-[#171717]" style={{ fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif' }}>
      {/* Top bar — same continuous gray surface as the sidebar */}
      <div className="flex h-[48px] shrink-0 items-center">
        <div className="flex w-[262px] shrink-0 items-center gap-[18px] pl-[18px]">
          <TrafficLights />
          <PanelLeft className="h-[16px] w-[16px] text-black/40" strokeWidth={1.6} />
        </div>
        <span className="truncate pl-6 text-[13px] font-medium text-black/65">Caching strategy for the API</span>
        <Columns2 className="ml-auto mr-[18px] h-[16px] w-[16px] text-black/40" strokeWidth={1.6} />
      </div>

      <div className="flex min-h-0 flex-1">
      {/* Sidebar */}
      <aside className="flex w-[262px] shrink-0 flex-col px-[7px]">
        <div className="mt-[2px] flex items-center gap-2 px-[15px] py-2">
          <span className="text-[20px] font-semibold tracking-[-0.01em]">Chat</span>
          <ChevronDown className="h-3 w-3 text-black/45" strokeWidth={2} />
        </div>
        <div className="mt-1 flex items-center gap-[10px] rounded-lg px-[16px] py-[10px] text-[14px]">
          <SquarePen className="h-[15px] w-[15px]" strokeWidth={1.6} /> New chat
        </div>
        <div className="flex items-center gap-[10px] rounded-lg px-[16px] py-[10px] text-[14px]">
          <Folder className="h-[15px] w-[15px]" strokeWidth={1.6} /> Projects
        </div>
        <div className="flex items-center gap-[9px] px-[16px] py-[10px] text-[13px] text-black/45">
          <Search className="h-[14px] w-[14px]" strokeWidth={1.7} /> Search conversations
        </div>
        <p className="px-[10px] pb-[7px] pt-[16px] text-[12px] text-black/35">Recents</p>
        <ul className="flex flex-col gap-[3px]">
          {RECENTS.map((r) => (
            <li
              key={r.title}
              className={`flex items-center gap-[9px] rounded-[8px] px-[10px] py-[7px] text-[13px] ${r.active ? 'bg-black/[0.06]' : ''}`}
            >
              <span className="flex h-[17px] w-4 items-center justify-center text-black/50">
                {r.agent ? <AgentGlyph /> : <MessageSquare className="h-[13px] w-[13px]" strokeWidth={1.6} />}
              </span>
              <span className="truncate">{r.title}</span>
            </li>
          ))}
        </ul>
        <div className="mt-auto flex items-center gap-[10px] px-[12px] pb-[14px] pt-3">
          <span className="flex h-7 w-7 items-center justify-center rounded-full bg-[#DADADA] text-[11px] font-semibold text-black/70">AM</span>
          <span className="text-[13px] font-medium">Alex Martin</span>
        </div>
      </aside>

      {/* Main canvas — inset on every exposed edge, rounded, off-white */}
      <main className="mb-[8px] mr-[8px] flex min-w-0 flex-1 flex-col overflow-hidden rounded-[10px] bg-[#FAFAFC] shadow-[0_0_0_1px_rgba(0,0,0,0.06)]">
        <div className="flex min-h-0 flex-1 flex-col items-center overflow-hidden px-10">
          <div className="flex w-full max-w-[680px] flex-col gap-6 pt-10">
            <div className="max-w-[78%] self-end rounded-[18px] bg-[#EDEDED] px-4 py-[10px] text-[15px] leading-[1.45]">
              Repeat requests to our API are slow. What caching strategy would you start with?
            </div>

            <div className="l-serif text-[16px] leading-[1.6] text-[#1C1C1E]">
              <p>Start with a short-lived response cache in front of the slowest read endpoints, keyed by the normalized request. Then adjust per route:</p>
              <ul className="mt-3 space-y-2 pl-5" style={{ listStyle: 'disc' }}>
                <li>
                  <strong className="font-semibold">Read-heavy routes</strong> — cache for 60 seconds and revalidate in the background.
                </li>
                <li>
                  <strong className="font-semibold">Per-user data</strong> — scope every key by account so nothing is shared between users.
                </li>
                <li>
                  <strong className="font-semibold">Writes</strong> — invalidate the affected keys instead of waiting for them to expire.
                </li>
              </ul>
              <div className="l-mono mt-4 rounded-[10px] bg-[#F1F1F3] px-4 py-3 text-[13px] leading-[1.6] text-[#2B2D31]">
                <span className="text-[#8A8F98]">// stale-while-revalidate</span>
                <br />
                cache.set(key, body, {'{'} ttl: 60, staleFor: 300 {'}'})
              </div>
            </div>

            <div className="-mt-2 flex items-center gap-3 text-black/35">
              <Copy className="h-[14px] w-[14px]" strokeWidth={1.7} />
              <RotateCcw className="h-[14px] w-[14px]" strokeWidth={1.7} />
            </div>
          </div>
        </div>

        {/* Composer */}
        <div className="flex shrink-0 justify-center px-10 pb-6">
          <div className="w-full max-w-[720px] rounded-[26px] bg-white px-[18px] pb-3 pt-[14px] shadow-[0_0_0_1px_rgba(0,0,0,0.10),0_8px_24px_-12px_rgba(0,0,0,0.12)]">
            <p className="text-[16px] text-black/30">Ask anything</p>
            <div className="mt-3 flex items-center gap-2">
              <span className="flex h-8 w-8 items-center justify-center rounded-full text-black/55">
                <Plus className="h-[17px] w-[17px]" strokeWidth={1.7} />
              </span>
              <span className="flex items-center gap-1.5 rounded-full bg-[#F3F3F3] px-3 py-[6px] text-[12.5px] font-medium text-black/70">
                Claude Sonnet 5 <ChevronDown className="h-3 w-3 text-black/40" strokeWidth={2} />
              </span>
              <span className="ml-auto flex h-8 w-8 items-center justify-center rounded-full bg-[#171717] text-white">
                <ArrowUp className="h-4 w-4" strokeWidth={2} />
              </span>
            </div>
          </div>
        </div>
      </main>
      </div>
    </div>
  );
}

export default ChatScreen;
