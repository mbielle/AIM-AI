import { FileText, Hand, MoreHorizontal, PencilLine, Search } from 'lucide-react';

/**
 * Feature visual, designed at 900 × 580 and scaled as a whole: an agent run in the background and,
 * in front, the permission request the Mac app shows before a sensitive action. Wording of the
 * request follows AIM-macOS WorkspaceApprovalView.swift (“Ask permission”, the provider/model
 * notice, “Deny” with Esc and “Allow once”). Content is fictional.
 */
export const APPROVAL_SCENE_SIZE = { width: 900, height: 580 };

const STEPS = [
  { icon: FileText, label: 'Read file', detail: 'src/auth/guard.ts' },
  { icon: Search, label: 'Searched', detail: 'restoreSession' },
  { icon: PencilLine, label: 'Proposed an edit', detail: 'src/auth/guard.ts' },
];

export function ApprovalScene() {
  return (
    <div className="relative h-full w-full" style={{ fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif' }}>
      {/* Background: the run itself, quieter than the request in front */}
      <div className="absolute left-[56px] top-[56px] h-[600px] w-[580px] rounded-[14px] bg-white/60 p-7 shadow-[0_0_0_1px_rgba(255,255,255,0.7)]">
        <div className="flex items-center gap-3 text-[16px] font-medium text-[#3A3D42]">
          Fix login redirect loop
          <MoreHorizontal className="h-4 w-4 text-black/35" strokeWidth={1.8} />
        </div>
        <div className="ml-auto mt-6 w-fit max-w-[85%] rounded-[16px] bg-white/80 px-4 py-[10px] text-[15px] leading-[1.45] text-[#4A4D53]">
          The login redirect loops after sign-in. Find why and fix it.
        </div>
        <ul className="mt-6 flex flex-col gap-[9px]">
          {STEPS.map(({ icon: Icon, label, detail }) => (
            <li key={label} className="flex items-center gap-[10px] text-[14px] text-black/45">
              <Icon className="h-[15px] w-[15px]" strokeWidth={1.7} />
              <span className="text-black/55">{label}</span>
              <span className="l-mono text-[12.5px] text-black/40">{detail}</span>
            </li>
          ))}
        </ul>
        <p className="l-serif mt-6 text-[16px] leading-[1.6] text-[#6A6E75]">
          The guard runs before the session is restored, so it sees no user and redirects again. I’ll wait for the restore, then run the auth tests to confirm.
        </p>
      </div>

      {/* Foreground: the permission request */}
      <div className="absolute right-[48px] top-[236px] w-[440px] rounded-[14px] bg-white px-5 py-[18px] shadow-[0_0_0_1px_rgba(15,18,24,0.08),0_2px_4px_rgba(15,18,24,0.05),0_24px_50px_-20px_rgba(15,18,24,0.3)]">
        <p className="flex items-center gap-1.5 text-[12px] font-medium text-black/50">
          <Hand className="h-[13px] w-[13px]" strokeWidth={1.8} /> Ask permission
        </p>
        <p className="mt-2 text-[15px] font-medium text-[#171717]">Run a command</p>
        <p className="l-mono mt-2.5 rounded-[8px] bg-[#F3F4F6] px-3 py-2 text-[13px] text-[#2B2D31]">npm test -- auth</p>
        <p className="mt-3 text-[12px] leading-[1.5] text-black/50">
          The result will be sent to Anthropic using claude-sonnet-5. This decision applies only to this action.
        </p>
        <div className="mt-4 flex justify-end gap-2 text-[13.5px] font-medium">
          <span className="flex items-center gap-2 rounded-[9px] px-3.5 py-2 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]">
            Deny
            <span className="rounded-[5px] bg-black/[0.05] px-1.5 py-px text-[11px] font-normal text-black/45">Esc</span>
          </span>
          <span className="rounded-[9px] bg-[#171717] px-3.5 py-2 text-white">Allow once</span>
        </div>
      </div>
    </div>
  );
}

export default ApprovalScene;
