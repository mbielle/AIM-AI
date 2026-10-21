import AIMCore
import Foundation

/// AIM's own selection for the Customize store: official remote connectors (checked to answer
/// as MCP servers) and featured skills. Logos are the companies' GitHub avatars.
public enum CustomizeCatalog {
    static func logo(_ githubOrg: String) -> String { "https://github.com/\(githubOrg).png?size=128" }

    /// A skill's or plugin's icon: its author's GitHub avatar (varied and recognisable).
    public static func ownerAvatar(_ owner: String) -> String? {
        let trimmed = owner.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return nil }
        return logo(trimmed)
    }

    public static let connectors: [StoreConnector] = ConnectorCatalog.connectors

    /// The connector page: a longer presentation, what it lets AIM do, and the publisher's docs.
    public struct ConnectorDetails: Sendable {
        public let about: String
        public let features: [String]
        public let docs: String?
    }

    public static let connectorDetails: [String: ConnectorDetails] = [
        "notion": .init(about: "Connect your Notion workspace so AIM can find the right page, read databases and keep your notes up to date while you talk.",
                        features: ["Search across pages and databases", "Read and summarize pages, including database entries", "Create pages and update content and properties"],
                        docs: "https://developers.notion.com/docs/mcp"),
        "linear": .init(about: "Plan and track work in Linear from a conversation: AIM can file issues, update their status and find what is blocking a project.",
                        features: ["Search issues, projects and cycles", "Create and update issues, labels and assignees", "Comment and summarize a project's progress"],
                        docs: "https://linear.app/docs/mcp"),
        "figma": .init(about: "Bring Figma context into AIM to turn designs into code that matches your components, variables and layouts.",
                       features: ["Generate code from selected frames or nodes", "Extract variables, components and layout from a design", "Map flows and diagrams in FigJam"],
                       docs: "https://help.figma.com/hc/en-us/articles/32132100833559"),
        "canva": .init(about: "Create, find and export Canva designs without leaving AIM.",
                       features: ["Search your designs and templates", "Create designs and autofill brand templates", "Export designs as PDF or images"],
                       docs: "https://www.canva.dev/docs/connect/canva-mcp-server-setup/"),
        "atlassian": .init(about: "Work with Jira and Confluence from AIM: triage issues, write pages and search your team's knowledge.",
                           features: ["Search, create and update Jira issues", "Read, create and edit Confluence pages", "Summarize sprints and spaces"],
                           docs: "https://support.atlassian.com/rovo/docs/getting-started-with-the-atlassian-remote-mcp-server/"),
        "github": .init(about: "Give AIM access to your GitHub repositories, issues and pull requests with a personal access token.",
                        features: ["Search code and browse repositories", "Read and create issues and pull requests", "Review changes and CI status"],
                        docs: "https://github.com/github/github-mcp-server"),
        "supabase": .init(about: "Administer your Supabase projects from AIM: tables, SQL, migrations and logs.",
                          features: ["List projects, tables and extensions", "Run SQL and apply migrations", "Read logs and generate TypeScript types"],
                          docs: "https://supabase.com/docs/guides/getting-started/mcp"),
        "neon": .init(about: "Manage Neon serverless Postgres: create branches, run queries and prepare migrations safely.",
                      features: ["Create and list projects and branches", "Run SQL queries", "Prepare and complete migrations on a branch"], docs: "https://neon.com/docs/ai/neon-mcp-server"),
        "vercel": .init(about: "Check your Vercel projects and deployments from AIM and find why a build failed.",
                        features: ["List projects and deployments", "Read build and runtime logs", "Search Vercel documentation"], docs: "https://vercel.com/docs/mcp/vercel-mcp"),
        "cloudflare": .init(about: "Build on Cloudflare's developer platform from AIM.",
                            features: ["Manage Workers, KV, R2 and D1", "Inspect bindings and resources", "Deploy and update configuration"], docs: "https://developers.cloudflare.com/agents/model-context-protocol/"),
        "sentry": .init(about: "Investigate production errors with AIM: find issues, read stack traces and see what changed.",
                        features: ["Search issues and events", "Read stack traces and breadcrumbs", "Summarize an incident and its impact"], docs: "https://docs.sentry.io/product/sentry-mcp/"),
        "stripe": .init(about: "Look up and manage your Stripe account from AIM: customers, payments, invoices and products.",
                        features: ["Search customers, payments and subscriptions", "Create invoices, products and payment links", "Search Stripe documentation"], docs: "https://docs.stripe.com/mcp"),
        "paypal": .init(about: "Work with PayPal from AIM: invoices, orders, disputes and transactions.",
                        features: ["Create and send invoices", "Look up orders and transactions", "Manage disputes and shipment tracking"], docs: "https://developer.paypal.com/tools/mcp-server/"),
        "square": .init(about: "Use Square's APIs from AIM: payments, catalog, orders and customers.",
                        features: ["Look up payments and orders", "Manage the catalog and inventory", "Find customers and their history"], docs: "https://developer.squareup.com/docs/mcp"),
        "intercom": .init(about: "Bring customer conversations from Intercom into AIM to answer and analyze faster.",
                          features: ["Search conversations and contacts", "Summarize customer issues", "Find related tickets"], docs: "https://developers.intercom.com/docs/guides/mcp"),
        "monday": .init(about: "Manage monday.com boards, items and updates from AIM.",
                        features: ["Search boards and items", "Create items and update columns", "Post updates"], docs: "https://developer.monday.com/apps/docs/mondaycom-mcp-integration"),
        "webflow": .init(about: "Edit Webflow sites, pages and CMS content from AIM.",
                         features: ["Read and update CMS collections", "Edit pages and site settings", "Publish changes"], docs: "https://developers.webflow.com/mcp/reference/overview"),
        "wix": .init(about: "Build and manage Wix sites, stores and bookings from AIM.",
                     features: ["Manage site content and store products", "Handle bookings and orders", "Search Wix documentation"], docs: "https://dev.wix.com/docs/sdk/articles/use-the-wix-mcp/about-the-wix-mcp"),
        "zapier": .init(about: "Reach thousands of apps through the actions you enable in Zapier.",
                        features: ["Run the Zapier actions you configured", "Connect apps that have no connector of their own", "Automate multi-step tasks"], docs: "https://zapier.com/mcp"),
        "huggingface": .init(about: "Explore the Hugging Face Hub from AIM: models, datasets, papers and Spaces.",
                             features: ["Search models and datasets", "Read model cards and papers", "Use Spaces as tools"], docs: "https://huggingface.co/settings/mcp"),
        "context7": .init(about: "Give AIM up-to-date documentation and code examples for the libraries you use, straight from the source.",
                          features: ["Resolve a library by name", "Fetch current docs for a version", "No account needed"], docs: "https://context7.com"),
        "deepwiki": .init(about: "Ask questions about any public GitHub repository and get answers grounded in its code and docs.",
                          features: ["Read a repository's structure", "Ask questions about its code", "No account needed"], docs: "https://docs.devin.ai/work-with-devin/deepwiki-mcp"),
        "exa": .init(about: "Web search built for AI: fresh results with their full text, so AIM can cite real sources.",
                     features: ["Search the web", "Read pages in full", "No account needed for basic use"], docs: "https://docs.exa.ai/reference/exa-mcp"),
    ]

    /// The banner of the Skills tab and the "New skills" row.
    public static let featuredSkills: [StoreSkill] = [
        StoreSkill(source: "anthropics/skills", skillId: "pdf", name: "pdf", description: "Read, fill, merge and create PDF files."),
        StoreSkill(source: "anthropics/skills", skillId: "docx", name: "docx", description: "Create and edit Word documents with tracked changes and comments."),
        StoreSkill(source: "anthropics/skills", skillId: "xlsx", name: "xlsx", description: "Build spreadsheets with formulas, formatting and charts."),
        StoreSkill(source: "anthropics/skills", skillId: "pptx", name: "pptx", description: "Create and edit PowerPoint presentations."),
        StoreSkill(source: "anthropics/skills", skillId: "skill-creator", name: "skill-creator", description: "Create new skills and improve existing ones."),
        StoreSkill(source: "anthropics/skills", skillId: "frontend-design", name: "frontend-design", description: "Distinctive, production-grade web interfaces."),
    ]

    /// Store categories for skills, matched against names and descriptions.
    public static let skillCategories: [(title: String, icon: String, keywords: [String])] = [
        ("Engineering", "chevron.left.forwardslash.chevron.right", ["code", "test", "debug", "review", "refactor", "git", "api", "architecture", "typescript", "python", "swift", "react"]),
        ("Files & documents", "doc.on.doc", ["pdf", "docx", "xlsx", "pptx", "document", "spreadsheet", "slides", "markdown"]),
        ("Design & media", "paintpalette", ["design", "ui", "css", "image", "video", "brand", "figma", "canvas"]),
        ("Data & analysis", "chart.bar", ["data", "sql", "analytics", "chart", "csv", "dashboard"]),
        ("Writing", "text.quote", ["write", "writing", "copy", "blog", "edit", "grammar"]),
        ("Productivity", "checklist", ["plan", "task", "todo", "meeting", "notes", "email", "calendar"]),
        ("AI & agents", "sparkles", ["agent", "prompt", "llm", "mcp", "skill", "model"]),
        ("Marketing & sales", "megaphone", ["marketing", "seo", "sales", "campaign", "social"]),
    ]

    public static func category(of skill: StoreSkill) -> String? {
        let text = (skill.name + " " + (skill.description ?? "")).lowercased()
        return skillCategories.first { category in category.keywords.contains { text.contains($0) } }?.title
    }
}

/// Plugins installed from the store: which skills and connectors each brought (to remove them together).
public struct InstalledPlugin: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var skills: [String]
    public var connectorIDs: [UUID]
    public var installedAt: Date

    public init(id: String, title: String, skills: [String], connectorIDs: [UUID], installedAt: Date = .now) {
        self.id = id; self.title = title; self.skills = skills; self.connectorIDs = connectorIDs; self.installedAt = installedAt
    }
}

public enum InstalledPlugins {
    static var file: URL? { SkillCatalog.globalDirectory?.appendingPathComponent(".plugins.json") }

    public static func all() -> [InstalledPlugin] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([InstalledPlugin].self, from: data)) ?? []
    }

    public static func save(_ plugins: [InstalledPlugin]) {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(plugins).write(to: file, options: .atomic)
    }
}
