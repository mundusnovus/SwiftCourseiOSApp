// The connector directory: hosted MCP servers anyone can add in a tap. Every fixed address here (48 of them; Zapier's
// is your own) was checked live on 5 November 2026 with an MCP initialize over Streamable HTTP. "Open" servers answered without signing in; "Sign in"
// servers answered 401 with OAuth metadata that allows dynamic client registration and PKCE, so Smartz registers
// itself and you sign in with the service. Google Workspace, Slack, HubSpot and Box don't allow dynamic registration,
// so they need an OAuth client ID you create with that service. GitHub and Apify take a token; Zapier gives you a URL.
// Any other MCP server can be added by its URL. Icons are SF Symbols, never the companies' logos. Every Asteria app
// shares the directory and your connectors (SmartzConnectors.swift).
import Foundation

nonisolated public struct SmartzConnectorEntry: Identifiable, Hashable, Sendable {
    public enum Auth: String, Sendable { case none, oauth, token, google, clientID, personalURL }
    public enum Category: String, CaseIterable, Sendable {
        case knowledge = "Knowledge and docs"
        case search = "Search and research"
        case google = "Google Workspace"
        case work = "Work and projects"
        case notes = "Notes, files and data"
        case design = "Design"
        case money = "Payments and commerce"
        case developer = "Developers"
        case meetings = "Meetings and calls"
        case automation = "Automation"
    }

    public let id: String
    public let name: String
    public let url: String
    public let symbol: String
    public let category: Category
    public let blurb: String
    public let auth: Auth
    public var help: String? = nil
    public var authorizeURL: String? = nil
    public var tokenURL: String? = nil
    public var scopes: [String] = []
}

nonisolated public enum SmartzConnectorCatalog {
    private static let googleAuthorize = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let googleToken = "https://oauth2.googleapis.com/token"
    private static let googleHelp = """
        Google's Workspace MCP servers are in Developer Preview and don't allow apps to register themselves. In Google \
        Cloud: join the Workspace Developer Preview, enable the API and its MCP service, then create an OAuth client of \
        type iOS with bundle ID \(SmartzMCPAuth.appID), and paste its client ID here.
        """

    public static let entries: [SmartzConnectorEntry] = [
        // Open: no account needed.
        .init(id: "deepwiki", name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", symbol: "books.vertical", category: .knowledge,
              blurb: "Ask questions about any public GitHub project and read its wiki.", auth: .none),
        .init(id: "context7", name: "Context7", url: "https://mcp.context7.com/mcp", symbol: "book.pages", category: .knowledge,
              blurb: "Up-to-date documentation and code examples for libraries and frameworks.", auth: .none),
        .init(id: "mslearn", name: "Microsoft Learn", url: "https://learn.microsoft.com/api/mcp", symbol: "graduationcap", category: .knowledge,
              blurb: "Search and read Microsoft and Azure documentation and code samples.", auth: .none),
        .init(id: "awsknowledge", name: "AWS Knowledge", url: "https://knowledge-mcp.global.api.aws", symbol: "server.rack", category: .knowledge,
              blurb: "AWS documentation, regional availability, and best practices.", auth: .none),
        .init(id: "cloudflaredocs", name: "Cloudflare Docs", url: "https://docs.mcp.cloudflare.com/mcp", symbol: "cloud", category: .knowledge,
              blurb: "Search Cloudflare's documentation.", auth: .none),
        .init(id: "gitmcp", name: "GitMCP", url: "https://gitmcp.io/docs", symbol: "text.book.closed", category: .knowledge,
              blurb: "Documentation and code from any GitHub repository.", auth: .none),
        .init(id: "huggingface", name: "Hugging Face", url: "https://huggingface.co/mcp", symbol: "face.smiling", category: .search,
              blurb: "Find models, datasets, papers and Spaces on the Hugging Face Hub.", auth: .none),
        .init(id: "exa", name: "Exa", url: "https://mcp.exa.ai/mcp", symbol: "magnifyingglass", category: .search,
              blurb: "AI web search that returns clean page content.", auth: .none),

        // Google Workspace: your own OAuth client ID.
        .init(id: "gmail", name: "Gmail", url: "https://gmailmcp.googleapis.com/mcp/v1", symbol: "envelope", category: .google,
              blurb: "Search and read your mail, manage labels, and write drafts.", auth: .google, help: googleHelp,
              authorizeURL: googleAuthorize, tokenURL: googleToken,
              scopes: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"]),
        .init(id: "gcalendar", name: "Google Calendar", url: "https://calendarmcp.googleapis.com/mcp/v1", symbol: "calendar", category: .google,
              blurb: "List, search, create and update events.", auth: .google, help: googleHelp,
              authorizeURL: googleAuthorize, tokenURL: googleToken, scopes: ["https://www.googleapis.com/auth/calendar"]),
        .init(id: "gdrive", name: "Google Drive", url: "https://drivemcp.googleapis.com/mcp/v1", symbol: "externaldrive", category: .google,
              blurb: "Search, read and create files in your Drive.", auth: .google, help: googleHelp,
              authorizeURL: googleAuthorize, tokenURL: googleToken, scopes: ["https://www.googleapis.com/auth/drive"]),
        .init(id: "gdocs", name: "Google Docs", url: "https://docsmcp.googleapis.com/mcp/v1", symbol: "doc.richtext", category: .google,
              blurb: "Read and update your documents.", auth: .google, help: googleHelp,
              authorizeURL: googleAuthorize, tokenURL: googleToken, scopes: ["https://www.googleapis.com/auth/documents"]),
        .init(id: "gsheets", name: "Google Sheets", url: "https://sheetsmcp.googleapis.com/mcp/v1", symbol: "tablecells", category: .google,
              blurb: "Read, update and format your spreadsheets.", auth: .google, help: googleHelp,
              authorizeURL: googleAuthorize, tokenURL: googleToken, scopes: ["https://www.googleapis.com/auth/spreadsheets"]),

        // Sign in (OAuth with dynamic registration).
        .init(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", symbol: "doc.text", category: .notes,
              blurb: "Search, read and write your Notion pages and databases.", auth: .oauth),
        .init(id: "airtable", name: "Airtable", url: "https://mcp.airtable.com/mcp", symbol: "tablecells.badge.ellipsis", category: .notes,
              blurb: "Read and update records in your bases.", auth: .oauth),
        .init(id: "dropbox", name: "Dropbox", url: "https://mcp.dropbox.com/mcp", symbol: "shippingbox", category: .notes,
              blurb: "Find, read and organise your files.", auth: .oauth),
        .init(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", symbol: "checklist", category: .work,
              blurb: "Create and update issues, projects and cycles.", auth: .oauth),
        .init(id: "atlassian", name: "Jira and Confluence", url: "https://mcp.atlassian.com/v1/mcp", symbol: "square.stack.3d.up", category: .work,
              blurb: "Atlassian's Jira issues and Confluence pages.", auth: .oauth),
        .init(id: "asana", name: "Asana", url: "https://mcp.asana.com/v2/mcp", symbol: "checkmark.circle", category: .work,
              blurb: "Tasks, projects and portfolios.", auth: .oauth),
        .init(id: "monday", name: "monday.com", url: "https://mcp.monday.com/mcp", symbol: "calendar.day.timeline.left", category: .work,
              blurb: "Boards, items and updates.", auth: .oauth),
        .init(id: "clickup", name: "ClickUp", url: "https://mcp.clickup.com/mcp", symbol: "list.bullet.rectangle", category: .work,
              blurb: "Tasks, docs and spaces.", auth: .oauth),
        .init(id: "miro", name: "Miro", url: "https://mcp.miro.com/", symbol: "rectangle.on.rectangle", category: .work,
              blurb: "Read and add to your boards.", auth: .oauth),
        .init(id: "intercom", name: "Intercom", url: "https://mcp.intercom.com/mcp", symbol: "bubble.left.and.text.bubble.right", category: .work,
              blurb: "Customer conversations and contacts.", auth: .oauth),
        .init(id: "calcom", name: "Cal.com", url: "https://mcp.cal.com/mcp", symbol: "calendar.badge.clock", category: .meetings,
              blurb: "Your bookings, availability and event types.", auth: .oauth),
        .init(id: "granola", name: "Granola", url: "https://mcp.granola.ai/mcp", symbol: "waveform.and.mic", category: .meetings,
              blurb: "Your meeting notes and transcripts.", auth: .oauth),
        .init(id: "krisp", name: "Krisp", url: "https://mcp.krisp.ai/mcp", symbol: "mic", category: .meetings,
              blurb: "Meeting transcripts and action items.", auth: .oauth),
        .init(id: "figma", name: "Figma", url: "https://mcp.figma.com/mcp", symbol: "paintpalette", category: .design,
              blurb: "Read designs, components and variables.", auth: .oauth),
        .init(id: "canva", name: "Canva", url: "https://mcp.canva.com/mcp", symbol: "paintbrush", category: .design,
              blurb: "Find, create and export your designs.", auth: .oauth),
        .init(id: "webflow", name: "Webflow", url: "https://mcp.webflow.com/mcp", symbol: "globe", category: .design,
              blurb: "Sites, CMS collections and publishing.", auth: .oauth),
        .init(id: "wix", name: "Wix", url: "https://mcp.wix.com/mcp", symbol: "globe.desk", category: .design,
              blurb: "Your Wix sites and their content.", auth: .oauth),
        .init(id: "stripe", name: "Stripe", url: "https://mcp.stripe.com", symbol: "creditcard", category: .money,
              blurb: "Customers, payments, subscriptions and invoices.", auth: .oauth),
        .init(id: "paypal", name: "PayPal", url: "https://mcp.paypal.com/mcp", symbol: "dollarsign.circle", category: .money,
              blurb: "Invoices, orders and transactions.", auth: .oauth),
        .init(id: "square", name: "Square", url: "https://mcp.squareup.com/mcp", symbol: "square.grid.2x2", category: .money,
              blurb: "Orders, catalog, customers and payments.", auth: .oauth),
        .init(id: "sentry", name: "Sentry", url: "https://mcp.sentry.dev/mcp", symbol: "ant", category: .developer,
              blurb: "Errors, issues and releases.", auth: .oauth),
        .init(id: "vercel", name: "Vercel", url: "https://mcp.vercel.com", symbol: "triangle", category: .developer,
              blurb: "Projects, deployments and logs.", auth: .oauth),
        .init(id: "supabase", name: "Supabase", url: "https://mcp.supabase.com/mcp", symbol: "cylinder", category: .developer,
              blurb: "Projects, databases and edge functions.", auth: .oauth),
        .init(id: "neon", name: "Neon", url: "https://mcp.neon.tech/mcp", symbol: "cylinder.split.1x2", category: .developer,
              blurb: "Serverless Postgres projects and branches.", auth: .oauth),
        .init(id: "prisma", name: "Prisma", url: "https://mcp.prisma.io/mcp", symbol: "cylinder.fill", category: .developer,
              blurb: "Prisma Postgres databases.", auth: .oauth),
        .init(id: "cloudflare", name: "Cloudflare", url: "https://mcp.cloudflare.com/mcp", symbol: "cloud.fill", category: .developer,
              blurb: "Your Cloudflare account: Workers, DNS, and more.", auth: .oauth),
        .init(id: "grafana", name: "Grafana", url: "https://mcp.grafana.com/mcp", symbol: "chart.xyaxis.line", category: .developer,
              blurb: "Dashboards, queries and alerts.", auth: .oauth),
        .init(id: "posthog", name: "PostHog", url: "https://mcp.posthog.com/mcp", symbol: "chart.bar", category: .developer,
              blurb: "Product analytics, flags and insights.", auth: .oauth),
        .init(id: "jam", name: "Jam", url: "https://mcp.jam.dev/mcp", symbol: "ladybug", category: .developer,
              blurb: "Bug reports with recordings and logs.", auth: .oauth),
        .init(id: "semgrep", name: "Semgrep", url: "https://mcp.semgrep.ai/mcp", symbol: "shield.lefthalf.filled", category: .developer,
              blurb: "Scan code for security problems.", auth: .oauth),

        // Your own OAuth app (no dynamic registration).
        .init(id: "slack", name: "Slack", url: "https://mcp.slack.com/mcp", symbol: "number", category: .work,
              blurb: "Search and read channels, and post messages.", auth: .clientID,
              help: "Slack needs an app of your own: create one at api.slack.com, add the redirect URL \(SmartzMCPAuth.redirectURI), and paste its client ID."),
        .init(id: "hubspot", name: "HubSpot", url: "https://mcp.hubspot.com/", symbol: "person.2.crop.square.stack", category: .work,
              blurb: "Contacts, companies, deals and tickets.", auth: .clientID,
              help: "HubSpot needs an MCP auth app of your own: create one in HubSpot's developer portal with the redirect URL \(SmartzMCPAuth.redirectURI), and paste its client ID."),
        .init(id: "box", name: "Box", url: "https://mcp.box.com", symbol: "archivebox", category: .notes,
              blurb: "Search and read your Box files.", auth: .clientID,
              help: "Box needs an OAuth app of your own: create one in the Box developer console with the redirect URL \(SmartzMCPAuth.redirectURI), and paste its client ID."),

        // Tokens and personal URLs.
        .init(id: "github", name: "GitHub", url: "https://api.githubcopilot.com/mcp/", symbol: "chevron.left.forwardslash.chevron.right", category: .developer,
              blurb: "Repositories, issues, pull requests and Actions.", auth: .token,
              help: "Make a fine-grained personal access token at github.com › Settings › Developer settings, and paste it here."),
        .init(id: "apify", name: "Apify", url: "https://mcp.apify.com", symbol: "ant.circle", category: .automation,
              blurb: "Thousands of ready-made web scrapers and automations.", auth: .token,
              help: "Paste your Apify API token (Apify Console › Settings › Integrations)."),
        .init(id: "zapier", name: "Zapier", url: "", symbol: "bolt.horizontal", category: .automation,
              blurb: "Thousands of apps through your own Zapier MCP server.", auth: .personalURL,
              help: "Make a server at zapier.com/mcp, choose its apps and actions, and paste its server URL here."),
    ]

    public static func entry(_ id: String?) -> SmartzConnectorEntry? { entries.first { $0.id == id } }
}
