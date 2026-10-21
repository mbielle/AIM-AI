import Foundation

public struct PortableConnector: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum Auth: String, Codable, Sendable { case oauth, token, none }
    public let id: String
    public let name: String
    public let description: String
    public let url: String?
    public let logo: String?
    public let category: String
    public let publisher: String
    public let auth: Auth
    /// Shown but not installable yet (e.g. Google, which needs AIM's own OAuth app).
    public let soon: Bool
    public let featured: Bool
    /// The header and hint for token connectors ("Authorization", "GitHub personal access token").
    public let tokenHint: String?
    /// Registry transport; absent for historical curated entries.
    public let transport: String?
    public var supportsIPhone: Bool {
        guard !soon, let url, URL(string: url)?.scheme == "https" else { return false }
        return transport != "sse" && transport != "stdio" && !url.hasSuffix("/sse")
    }

    public init(id: String, name: String, description: String, url: String?, logo: String? = nil, category: String,
                publisher: String, auth: Auth = .oauth, soon: Bool = false, featured: Bool = false, tokenHint: String? = nil, transport: String? = nil) {
        self.id = id; self.name = name; self.description = description; self.url = url; self.logo = logo
        self.category = category; self.publisher = publisher; self.auth = auth; self.soon = soon
        self.featured = featured; self.tokenHint = tokenHint; self.transport = transport
    }
}

public enum ConnectorCatalog {
    private static func logo(_ org: String) -> String { "https://github.com/\(org).png?size=128" }
    public static let connectors: [PortableConnector] = [
        PortableConnector(id: "notion", name: "Notion", description: "Search, read and update your Notion pages and databases.",
                       url: "https://mcp.notion.com/mcp", logo: logo("makenotion"), category: "Notes & docs", publisher: "Notion", featured: true),
        PortableConnector(id: "linear", name: "Linear", description: "Create and update issues, projects and cycles in Linear.",
                       url: "https://mcp.linear.app/mcp", logo: logo("linear"), category: "Tickets & tasks", publisher: "Linear", featured: true),
        PortableConnector(id: "figma", name: "Figma", description: "Read designs, components and variables to turn them into code.",
                       url: "https://mcp.figma.com/mcp", logo: logo("figma"), category: "Design & media", publisher: "Figma", featured: true),
        PortableConnector(id: "canva", name: "Canva", description: "Search, create, autofill and export Canva designs.",
                       url: "https://mcp.canva.com/mcp", logo: logo("canva-sdks"), category: "Design & media", publisher: "Canva", featured: true),
        PortableConnector(id: "atlassian", name: "Atlassian", description: "Jira issues and Confluence pages: search, create and update.",
                       url: "https://mcp.atlassian.com/v1/mcp", logo: logo("atlassian"), category: "Tickets & tasks", publisher: "Atlassian", featured: true),
        PortableConnector(id: "asana", name: "Asana", description: "Tasks, projects and goals in your Asana workspace.",
                       url: "https://mcp.asana.com/v2/mcp", logo: logo("Asana"), category: "Tickets & tasks", publisher: "Asana", soon: true),
        PortableConnector(id: "github", name: "GitHub", description: "Repositories, issues, pull requests and code search.",
                       url: "https://api.githubcopilot.com/mcp/", logo: logo("github"), category: "Engineering", publisher: "GitHub",
                       auth: .token, featured: true, tokenHint: "A GitHub personal access token (github.com/settings/tokens)"),
        PortableConnector(id: "supabase", name: "Supabase", description: "Manage tables, run SQL and administer your Supabase projects.",
                       url: "https://mcp.supabase.com/mcp", logo: logo("supabase"), category: "Databases", publisher: "Supabase"),
        PortableConnector(id: "neon", name: "Neon", description: "Serverless Postgres: branches, queries and migrations.",
                       url: "https://mcp.neon.tech/mcp", logo: logo("neondatabase"), category: "Databases", publisher: "Neon"),
        PortableConnector(id: "vercel", name: "Vercel", description: "Projects, deployments and logs on Vercel.",
                       url: "https://mcp.vercel.com", logo: logo("vercel"), category: "Engineering", publisher: "Vercel"),
        PortableConnector(id: "cloudflare", name: "Cloudflare", description: "Workers, KV, R2 and D1 in your Cloudflare account.",
                       url: "https://bindings.mcp.cloudflare.com/mcp", logo: logo("cloudflare"), category: "Engineering", publisher: "Cloudflare"),
        PortableConnector(id: "sentry", name: "Sentry", description: "Errors, issues and performance data from Sentry.",
                       url: "https://mcp.sentry.dev/mcp", logo: logo("getsentry"), category: "Logs & errors", publisher: "Sentry"),
        PortableConnector(id: "stripe", name: "Stripe", description: "Customers, payments, invoices and products in Stripe.",
                       url: "https://mcp.stripe.com", logo: logo("stripe"), category: "Finance", publisher: "Stripe", featured: true),
        PortableConnector(id: "paypal", name: "PayPal", description: "Invoices, orders and transactions on PayPal.",
                       url: "https://mcp.paypal.com/mcp", logo: logo("paypal"), category: "Finance", publisher: "PayPal"),
        PortableConnector(id: "square", name: "Square", description: "Payments, catalog, orders and customers on Square.",
                       url: "https://mcp.squareup.com/sse", logo: logo("square"), category: "Retail & e-commerce", publisher: "Square"),
        PortableConnector(id: "hubspot", name: "HubSpot", description: "Contacts, companies and deals in your HubSpot CRM.",
                       url: "https://mcp.hubspot.com/", logo: logo("HubSpot"), category: "Contacts & leads", publisher: "HubSpot", soon: true),
        PortableConnector(id: "intercom", name: "Intercom", description: "Conversations and customer data from Intercom.",
                       url: "https://mcp.intercom.com/mcp", logo: logo("intercom"), category: "Contacts & leads", publisher: "Intercom"),
        PortableConnector(id: "monday", name: "monday.com", description: "Boards, items and updates on monday.com.",
                       url: "https://mcp.monday.com/mcp", logo: logo("mondaycom"), category: "Tickets & tasks", publisher: "monday.com"),
        PortableConnector(id: "box", name: "Box", description: "Search and read files stored in Box.",
                       url: "https://mcp.box.com", logo: logo("box"), category: "Files & documents", publisher: "Box", soon: true),
        PortableConnector(id: "webflow", name: "Webflow", description: "Sites, pages and CMS collections on Webflow.",
                       url: "https://mcp.webflow.com/mcp", logo: logo("webflow"), category: "Websites", publisher: "Webflow"),
        PortableConnector(id: "wix", name: "Wix", description: "Build and manage Wix sites, stores and bookings.",
                       url: "https://mcp.wix.com/mcp", logo: logo("wix"), category: "Websites", publisher: "Wix"),
        PortableConnector(id: "zapier", name: "Zapier", description: "Run actions in thousands of apps through Zapier.",
                       url: "https://mcp.zapier.com/api/mcp/mcp", logo: logo("zapier"), category: "Automation & workflows", publisher: "Zapier"),
        PortableConnector(id: "huggingface", name: "Hugging Face", description: "Search models, datasets, papers and Spaces.",
                       url: "https://huggingface.co/mcp", logo: logo("huggingface"), category: "AI & research", publisher: "Hugging Face", featured: true),
        PortableConnector(id: "context7", name: "Context7", description: "Up-to-date documentation for any library, in the prompt.",
                       url: "https://mcp.context7.com/mcp", logo: logo("upstash"), category: "Reference docs", publisher: "Upstash", auth: .none),
        PortableConnector(id: "deepwiki", name: "DeepWiki", description: "Ask questions about any public GitHub repository.",
                       url: "https://mcp.deepwiki.com/mcp", logo: logo("CognitionAI"), category: "Reference docs", publisher: "Cognition", auth: .none),
        PortableConnector(id: "exa", name: "Exa", description: "Web search built for AI: fresh results with full text.",
                       url: "https://mcp.exa.ai/mcp", logo: logo("exa-labs"), category: "AI & research", publisher: "Exa", auth: .none),
        PortableConnector(id: "gmail", name: "Gmail", description: "Draft replies, summarize threads and search your inbox.",
                       url: nil, logo: logo("google"), category: "Email & messages", publisher: "Google", soon: true, featured: true),
        PortableConnector(id: "google-drive", name: "Google Drive", description: "Search, read and upload files.",
                       url: nil, logo: logo("google"), category: "Files & documents", publisher: "Google", soon: true),
        PortableConnector(id: "google-calendar", name: "Google Calendar", description: "Manage your schedule and coordinate meetings.",
                       url: nil, logo: logo("google"), category: "Events & tickets", publisher: "Google", soon: true),
        PortableConnector(id: "microsoft-365", name: "Microsoft 365", description: "Outlook, OneDrive, SharePoint and Teams.",
                       url: nil, logo: logo("microsoft"), category: "Email & messages", publisher: "Microsoft", soon: true),
        PortableConnector(id: "slack", name: "Slack", description: "Search channels, read threads and send messages.",
                       url: nil, logo: logo("slackapi"), category: "Email & messages", publisher: "Slack", soon: true),
    ]

}
