import { releaseLinks, sourceUrl } from './releaseLinks';

export const LINKS = {
  macDownload: releaseLinks.macDownload,
  appStore: releaseLinks.iphone,
  source: sourceUrl,
  guide: '/guide',
  notice: '/legal',
  privacy: '/privacy',
  terms: '/terms',
  cookies: '/cookies',
  contact: 'mailto:contact@aim-ai.tech',
};

export const SOCIAL = sourceUrl ? [{ label: 'Source code', href: sourceUrl }] : [];

export const NAV = {
  menu: 'Menu',
  close: 'Close',
  download: 'Download for Mac',
  guide: 'Setup guide',
  socialTitle: 'Project links',
  // Absolute anchors so the same navigation works from the legal pages.
  product: {
    title: 'Product',
    links: [
      { label: 'Home', href: '/#top' },
      { label: 'Product', href: '/#product' },
      { label: 'Features', href: '/#features' },
      { label: 'Use cases', href: '/#use-cases' },
      { label: 'Pricing', href: '/#pricing' },
      { label: 'FAQ', href: '/#faq' },
    ],
  },
  getAim: {
    title: 'Get AIM',
  },
  bottom: [
    { label: 'Contact', href: LINKS.contact },
    { label: 'Legal', href: LINKS.notice },
  ],
};

export const HERO = {
  title: 'All your AI in one place.',
  subtitle: 'One workspace for the models and agents you already use.',
  download: 'Download for Mac',
  guide: 'Setup guide',
  free: 'Free and open source · Your keys or local models on Mac',
  requirements: 'Mac distribution is being prepared. See the setup guide for current requirements.',
  downloadUnavailable: 'Download link available soon',
  soon: 'Soon',
};

export const STORY = {
  title: 'See AIM at work',
  caption: 'Illustrative interface · sample data',
  steps: [
    { at: 0, title: 'Ask anything.', sub: 'Chat with the model that fits the question.' },
    { at: 0.2, title: 'Pick any model.', sub: 'Switch models in the composer, mid-conversation.' },
    { at: 0.4, title: 'Hand it a task.', sub: 'Agent reads, searches and proposes changes in your folder.' },
    { at: 0.6, title: 'Set the permissions.', sub: 'Choose a permission level. Sensitive actions ask for approval.' },
    { at: 0.8, title: 'Pick up where it left off.', sub: 'The run continues once you allow it, in the same history.' },
  ],
};

export const FEATURES = {
  title: 'One app.',
  titleMuted: 'Your models, your agents.',
  intro: 'AIM brings your models and agents into one native Mac workspace, with your own provider keys and one history.',
  previewLabel: 'Preview',
  items: [
    {
      id: 'models',
      title: 'Your choice of models',
      body: 'Connect OpenAI, Anthropic, Google Gemini, xAI, DeepSeek and Perplexity with your own keys — and hundreds more through OpenRouter.',
      media: 'feat-models',
    },
    {
      id: 'history',
      title: 'Chat, Code and Agent in one history',
      body: 'Ask, build and delegate side by side. Projects keep their files and instructions with the conversations that use them.',
      media: 'feat-history',
    },
    {
      id: 'approvals',
      title: 'Agents that ask before they act',
      body: 'Choose the files and actions an agent may use. Permission levels let routine work continue, with approval for sensitive actions.',
      media: 'feat-approvals',
    },
    {
      id: 'agents',
      title: 'Bring the agents you already use',
      body: 'Run OpenClaw and Hermes next to AIM’s own agent, and reuse your skills in the SKILL.md format.',
      media: 'feat-agents',
    },
    {
      id: 'remote',
      title: 'Continue from your iPhone',
      body: 'Your iPhone drives AIM on your Mac, which runs every model call with your keys. Follow an agent and approve its actions through a configured Remote backend.',
      media: 'feat-remote',
    },
  ],
} as const;

export const USE_CASES = {
  title: 'Built for every kind of work',
  intro: 'The same workspace, whether you are shipping code, reading a pile of documents or keeping an eye on a long task.',
  items: [
    { category: 'Software', title: 'Debug a project end to end.', media: 'uc-debug' },
    { category: 'Research', title: 'Analyze documents with several models.', media: 'uc-docs' },
    { category: 'Operations', title: 'Delegate a task with clear permissions.', media: 'uc-delegate' },
    { category: 'On the go', title: 'Follow your Mac from your iPhone.', media: 'uc-iphone' },
  ],
  wide: {
    category: 'Your models, your agents',
    title: 'Hundreds of models through OpenRouter. OpenClaw and Hermes next to AIM’s own agent.',
    media: 'uc-every-model',
  },
} as const;

export const PRICING = {
  title: 'Free and open source',
  intro: 'Chat, Code, Agent and Remote have no AIM subscription or feature paywall.',
  plan: 'AIM', price: 'Free',
  includes: ['Chat, projects, Code and Agent', 'Your own provider API keys', 'Supported local models on Mac', 'Remote with a configured backend and a paired Mac'],
  providerNote: 'API usage is billed by your provider. Local models run on your own hardware. Optional hosted services may have hosting costs.',
  remoteNote: 'The official Remote service may apply capacity and cost limits. Self-hosting requires a backend; Remote is not serverless. Your Mac must stay awake with AIM running.',
};

export const CTA_FINAL = {
  title: 'All your AI,',
  titleMuted: 'finally in one place.',
  body: 'Download AIM for Mac and bring your models and agents together.',
};

export const FOOTER = {
  tagline: 'All your AI in one place.',
  columns: [
    {
      title: 'Product',
      links: [
        { label: 'Overview', href: '/#product' },
        { label: 'Features', href: '/#features' },
        { label: 'Use cases', href: '/#use-cases' },
        { label: 'Pricing', href: '/#pricing' },
        { label: 'FAQ', href: '/#faq' },
      ],
    },
    {
      title: 'Download',
      // Destinations come from LINKS; without one the entry stays visible as “Soon”, never a fake link.
      downloads: [
        { label: 'AIM for Mac', key: 'macDownload' as const },
        { label: 'AIM for iPhone', key: 'appStore' as const },
      ],
    },
    {
      title: 'Legal',
      links: [
        { label: 'Legal notice', href: LINKS.notice },
        { label: 'Terms of use', href: LINKS.terms },
        { label: 'Privacy policy', href: LINKS.privacy },
        { label: 'Cookie policy', href: LINKS.cookies },
      ],
    },
    {
      title: 'Project',
      social: true as const,
      links: [{ label: 'Contact', href: LINKS.contact }],
    },
  ],
  privacyChoices: 'Privacy choices',
  soon: 'Soon',
  copyright: `© ${new Date().getFullYear()} AIM.AI`,
};

export const REMOTE = {
  appStore: 'AIM for iPhone',
  appStoreUnavailable: 'Public distribution is being prepared. No public download is enabled here.',
};

export const FAQ = {
  title: 'Common questions',
  contactLead: 'Still have a question?',
  contactLink: 'Write to us',
  contactTail: '— we read every message.',
  items: [
    {
      q: 'What is AIM?',
      a: 'A native Mac app whose official release is being prepared. Capabilities have been tested in qualification builds. AIM brings chat, agents and code together for the AI models you already use. You connect your own provider keys; AIM gives you one workspace and one history.',
    },
    {
      q: 'Which models can I use?',
      a: 'Models from the providers you connect with your own API keys: OpenAI, Anthropic, Google Gemini, xAI, DeepSeek, OpenRouter and Perplexity. Each request is billed by its provider. Consumer subscriptions such as ChatGPT Plus cannot be connected.',
    },
    {
      q: 'What can agents do on my Mac?',
      a: 'In Code and Agent, AIM can read files, propose and apply edits and run commands in the folder you choose. Sensitive actions ask for your approval first; configurable permission levels allow routine work within your authorization while sensitive actions ask.',
    },
    {
      q: 'Can I use other agents, like OpenClaw or Hermes?',
      a: 'Yes. AIM runs OpenClaw and Hermes next to its own agent, with configurable permissions, and reads skills in the SKILL.md format used by Claude, OpenClaw and Hermes.',
    },
    {
      q: 'What does AIM cost?',
      a: 'AIM is free and open source, with no trial, subscription or paid feature gates. Bring your own API keys and pay your provider directly, or use supported local models on Mac. Local inference depends on your hardware and installed runtime. Hosted Remote and optional services may have capacity or cost limits; self-hosting has its own infrastructure costs.',
    },
    {
      q: 'How does remote access work?',
      a: 'Remote requires an account, a configured backend and device pairing. The AIM app for iPhone sends your instructions to AIM on your Mac through your AIM account, and the Mac runs every model call with your keys. Your Mac needs to be on and awake with AIM open, both devices must use the same account, and your iPhone must be paired.',
    },
    {
      q: 'What do I need?',
      a: 'A supported Mac build and either your own provider API key or a supported local model runtime. Check the release requirements before installing. The iPhone app is optional and only needed for remote access.',
    },
  ],
};
