import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { makeDispatcher, requireEnv, bearerAuth, jsonGet, toolError } from "../_lib/common.js";

// ── Config ────────────────────────────────────────────────────────────────────

// Canonical .env names, passed through by docker compose env_file and inherited
// by whatever process spawns this server. Confluence Data Center authenticates
// the PAT as a Bearer token (same as Jira DC) — not Basic — so no username is
// needed. CONFLUENCE_BASE_URL must include the port if Confluence is served on
// its default 8090 connector (e.g. http://confluence.internal.example:8090).
requireEnv(["CONFLUENCE_BASE_URL", "CONFLUENCE_PAT"]);
const CONFLUENCE_BASE_URL = process.env.CONFLUENCE_BASE_URL;
const CONFLUENCE_PAT      = process.env.CONFLUENCE_PAT;

// TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in policy.yaml).
// Do NOT re-add rejectUnauthorized:false — a locked-down image must not skip
// certificate verification. If a TLS Confluence fails here, the CA isn't in the
// baked bundle; fix the CA, don't disable the check.
const dispatcher = makeDispatcher();

// ── Helpers ───────────────────────────────────────────────────────────────────

function confluenceHeaders() {
    return {
        "Authorization": bearerAuth(CONFLUENCE_PAT),
        "Content-Type": "application/json",
        "Accept": "application/json"
    };
}

async function confluenceGet(path) {
    return jsonGet(`${CONFLUENCE_BASE_URL}/rest/api${path}`, confluenceHeaders(), dispatcher);
}

function formatDate(isoString) {
    return isoString ? isoString.split("T")[0] : "unknown";
}

// Confluence page bodies come back in "storage format" — XHTML with custom
// <ac:.../> macro tags. There's no faithful round-trip to plain text, so this is
// a deliberately simple rendering: drop tags, decode the handful of entities
// that actually show up, and collapse whitespace. Good enough to read a page;
// not a substitute for opening it in the browser for complex macro-heavy pages.
function stripStorageFormat(html) {
    if (!html) return "(empty page)";
    return html
        .replace(/<\s*(br|\/p|\/h[1-6]|\/li|\/tr)\s*\/?\s*>/gi, "\n")
        .replace(/<[^>]+>/g, "")
        .replace(/&nbsp;/g, " ")
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'")
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim() || "(empty page)";
}

function pageUrl(content) {
    const webui = content?._links?.webui;
    if (webui) return `${CONFLUENCE_BASE_URL}${webui}`;
    if (content?.id) return `${CONFLUENCE_BASE_URL}/pages/viewpage.action?pageId=${content.id}`;
    return CONFLUENCE_BASE_URL;
}

function formatPage(content) {
    const body = content.body?.storage?.value;
    const ancestors = content.ancestors?.map(a => a.title).filter(Boolean) ?? [];

    const lines = [
        `📄  ${content.title}`,
        `🔗  ${pageUrl(content)}`,
        `─────────────────────────────────────────`,
        `ID:        ${content.id}`,
        `Type:      ${content.type ?? "—"}`,
        `Space:     ${content.space?.name ?? content.space?.key ?? "—"} (${content.space?.key ?? "—"})`,
        `Version:   ${content.version?.number ?? "—"} (updated ${formatDate(content.version?.when)} by ${content.version?.by?.displayName ?? "—"})`,
    ];

    if (ancestors.length) {
        lines.push(`Path:      ${ancestors.join(" › ")} › ${content.title}`);
    }

    lines.push(`─────────────────────────────────────────`);
    lines.push(`📋 CONTENT`);
    lines.push(stripStorageFormat(body));
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatSearchResults(results, cql, total) {
    if (!results.length) {
        return `No content found for CQL: ${cql}`;
    }

    const lines = [
        `🔍  Search results for CQL: ${cql}`,
        `    Showing ${results.length} of ${total} results`,
        `─────────────────────────────────────────`,
    ];

    for (const r of results) {
        // /content/search returns the content object directly; /search wraps it
        // under `.content`. Handle both so either endpoint shape works.
        const c = r.content ?? r;
        lines.push(`[${c.type ?? "?"}]  ${c.title ?? r.title ?? "(untitled)"}`);
        lines.push(`  Space: ${c.space?.key ?? "—"}  ID: ${c.id ?? "—"}`);
        lines.push(`  🔗 ${pageUrl(c)}`);
        lines.push(``);
    }

    if (total > results.length) {
        lines.push(`─────────────────────────────────────────`);
        lines.push(`⚠️  ${total - results.length} more results not shown. Refine your CQL or increase limit.`);
    }

    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatSpaces(spaces) {
    if (!spaces.length) return "No spaces found.";
    const lines = [
        `🗂️  Spaces (${spaces.length})`,
        `─────────────────────────────────────────`,
    ];
    for (const s of spaces) {
        lines.push(`${s.key}  [${s.type ?? "—"}]  ${s.name ?? ""}`);
    }
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatChildren(results, parentId) {
    if (!results.length) return `Page ${parentId} has no child pages.`;
    const lines = [
        `🌿  Child pages of ${parentId} (${results.length})`,
        `─────────────────────────────────────────`,
    ];
    for (const c of results) {
        lines.push(`${c.title}  (ID: ${c.id})`);
        lines.push(`  🔗 ${pageUrl(c)}`);
    }
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

// ── MCP Server ────────────────────────────────────────────────────────────────

const server = new McpServer({
    name: "confluence",
    version: "1.0.0"
});

// ── Tool: get_page ──────────────────────────────────────────────────────────--

server.tool(
    "get_page",
    "Fetch a Confluence page's full content and metadata. Provide either its numeric id, OR both spaceKey and title.",
    {
        id:       z.string().optional().describe("The numeric Confluence page/content id, e.g. 123456"),
        spaceKey: z.string().optional().describe("Space key (use together with title when you don't have the id)"),
        title:    z.string().optional().describe("Exact page title (use together with spaceKey)")
    },
    async ({ id, spaceKey, title }) => {
        try {
            const expand = "body.storage,version,space,ancestors";
            let content;

            if (id) {
                const { status, ok, data } = await confluenceGet(`/content/${encodeURIComponent(id.trim())}?expand=${expand}`);
                if (status === 401 || status === 403) {
                    return { content: [{ type: "text", text: `Authentication failed (${status}). Check CONFLUENCE_PAT.` }] };
                }
                if (status === 404) {
                    return { content: [{ type: "text", text: `Page ${id} not found.` }] };
                }
                if (!ok) {
                    return { content: [{ type: "text", text: `Unexpected error fetching page ${id}: HTTP ${status}` }] };
                }
                content = data;
            } else if (spaceKey && title) {
                const params = new URLSearchParams({ spaceKey, title, expand, limit: "1" });
                const { status, ok, data } = await confluenceGet(`/content?${params}`);
                if (status === 401 || status === 403) {
                    return { content: [{ type: "text", text: `Authentication failed (${status}). Check CONFLUENCE_PAT.` }] };
                }
                if (!ok) {
                    return { content: [{ type: "text", text: `Unexpected error looking up "${title}" in ${spaceKey}: HTTP ${status}` }] };
                }
                content = data.results?.[0];
                if (!content) {
                    return { content: [{ type: "text", text: `No page titled "${title}" found in space ${spaceKey}.` }] };
                }
            } else {
                return { content: [{ type: "text", text: `Provide either id, or both spaceKey and title.` }] };
            }

            return { content: [{ type: "text", text: formatPage(content) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: search ──────────────────────────────────────────────────────────────

server.tool(
    "search",
    "Search Confluence using CQL (Confluence Query Language). Returns matching content with title, type, space and a link.",
    {
        cql:   z.string().describe("CQL query, e.g. 'space = ENG AND type = page AND text ~ \"runbook\"'"),
        limit: z.number().optional().default(20).describe("Maximum number of results to return (default 20, max 50)")
    },
    async ({ cql, limit = 20 }) => {
        try {
            const params = new URLSearchParams({
                cql,
                limit: String(Math.min(limit, 50)),
                expand: "space,version"
            });

            const { status, ok, data } = await confluenceGet(`/content/search?${params}`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check CONFLUENCE_PAT.` }] };
            }
            if (status === 400) {
                return { content: [{ type: "text", text: `Invalid CQL query: ${cql}\nCheck your query syntax and try again.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error running search: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatSearchResults(data.results ?? [], cql, data.totalSize ?? data.size ?? 0) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_page_children ─────────────────────────────────────────────────--

server.tool(
    "get_page_children",
    "List the direct child pages of a Confluence page, for browsing a space's page tree.",
    { id: z.string().describe("The numeric id of the parent page") },
    async ({ id }) => {
        try {
            const { status, ok, data } = await confluenceGet(`/content/${encodeURIComponent(id.trim())}/child/page?limit=100`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check CONFLUENCE_PAT.` }] };
            }
            if (status === 404) {
                return { content: [{ type: "text", text: `Page ${id} not found.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error fetching children of ${id}: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatChildren(data.results ?? [], id) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: list_spaces ─────────────────────────────────────────────────────────

server.tool(
    "list_spaces",
    "List Confluence spaces (key, name, type). Useful to discover space keys before a scoped search.",
    { limit: z.number().optional().default(50).describe("Maximum number of spaces to return (default 50, max 100)") },
    async ({ limit = 50 }) => {
        try {
            const { status, ok, data } = await confluenceGet(`/space?limit=${Math.min(limit, 100)}`);

            if (!ok) {
                return { content: [{ type: "text", text: `Failed to list spaces: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatSpaces(data.results ?? []) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_current_user ────────────────────────────────────────────────────

server.tool(
    "get_current_user",
    "Returns the currently authenticated Confluence user. Call this first when you need the current user's username, e.g. before a CQL search using creator = currentUser().",
    {},
    async () => {
        try {
            const { status, ok, data } = await confluenceGet("/user/current");

            if (!ok) {
                return { content: [{ type: "text", text: `Failed to get current user: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: `Current Confluence user: ${data.displayName} (username: ${data.username ?? data.name}, email: ${data.email ?? "—"})` }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Start ─────────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
