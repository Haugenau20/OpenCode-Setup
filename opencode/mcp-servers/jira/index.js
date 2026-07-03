import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { makeDispatcher, requireEnv, bearerAuth, jsonGet, toolError } from "../_lib/common.js";

// ── Config ────────────────────────────────────────────────────────────────────

// Canonical .env names, passed through by docker compose env_file and inherited
// by whatever process spawns this server. Jira Data Center authenticates the
// PAT as a Bearer token (verified) — not Basic — so no username is needed.
requireEnv(["JIRA_BASE_URL", "JIRA_PAT"]);
const JIRA_BASE_URL = process.env.JIRA_BASE_URL;
const JIRA_PAT      = process.env.JIRA_PAT;

// TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in policy.yaml).
// Do NOT re-add rejectUnauthorized:false — a locked-down image must not skip
// certificate verification. If a TLS Jira fails here, the CA isn't in the baked
// bundle; fix the CA, don't disable the check.
const dispatcher = makeDispatcher();

// ── Helpers ───────────────────────────────────────────────────────────────────

function jiraHeaders() {
    return {
        "Authorization": bearerAuth(JIRA_PAT),
        "Content-Type": "application/json",
        "Accept": "application/json"
    };
}

async function jiraGet(path) {
    return jsonGet(`${JIRA_BASE_URL}/rest/api/2${path}`, jiraHeaders(), dispatcher);
}

function formatDate(isoString) {
    return isoString ? isoString.split("T")[0] : "unknown";
}

function extractText(node) {
    if (!node) return "";
    if (typeof node === "string") return node;
    if (node.type === "text") return node.text ?? "";
    if (node.content) return node.content.map(extractText).join("");
    return "";
}

function extractDescription(description) {
    if (!description) return "(no description provided)";
    if (typeof description === "string") return description.trim();
    if (typeof description === "object") return extractText(description).trim() || "(no description provided)";
    return String(description);
}

function extractCommentBody(body) {
    if (!body) return "";
    if (typeof body === "string") return body.trim();
    if (typeof body === "object") return extractText(body).trim();
    return String(body);
}

function formatIssue(issue, comments) {
    const f = issue.fields;
    const key = issue.key;

    const lines = [
        `🎫  ${key} — ${f.summary}`,
        `🔗  ${JIRA_BASE_URL}/browse/${key}`,
        `─────────────────────────────────────────`,
        `Type:       ${f.issuetype?.name ?? "—"}`,
        `Priority:   ${f.priority?.name ?? "—"}`,
        `Status:     ${f.status?.name ?? "—"}`,
        `Assignee:   ${f.assignee?.displayName ?? "Unassigned"}`,
        `Reporter:   ${f.reporter?.displayName ?? "—"}`,
        `Created:    ${formatDate(f.created)}`,
    ];

    if (f.components?.length) {
        lines.push(`Components: ${f.components.map(c => c.name).join(", ")}`);
    }
    if (f.labels?.length) {
        lines.push(`Labels:     ${f.labels.join(", ")}`);
    }

    lines.push(`─────────────────────────────────────────`);
    lines.push(`📋 DESCRIPTION`);
    lines.push(extractDescription(f.description));

    if (f.issuelinks?.length) {
        lines.push(`─────────────────────────────────────────`);
        lines.push(`🔗 LINKED ISSUES`);
        for (const link of f.issuelinks) {
            const linked = link.inwardIssue || link.outwardIssue;
            const direction = link.inwardIssue ? link.type.inward : link.type.outward;
            if (linked) {
                lines.push(`  ${direction}: ${linked.key} — ${linked.fields.summary} [${linked.fields.status.name}]`);
            }
        }
    }

    if (comments?.length) {
        lines.push(`─────────────────────────────────────────`);
        lines.push(`💬 COMMENTS (${comments.length})`);
        for (const comment of comments) {
            lines.push(``);
            lines.push(`[${comment.author.displayName} — ${formatDate(comment.created)}]`);
            lines.push(extractCommentBody(comment.body));
        }
    }

    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatSearchResults(issues, jql, total) {
    if (!issues.length) {
        return `No issues found for query: ${jql}`;
    }

    const lines = [
        `🔍  Search results for: ${jql}`,
        `    Showing ${issues.length} of ${total} issues`,
        `─────────────────────────────────────────`,
    ];

    for (const issue of issues) {
        const f = issue.fields;
        lines.push(`${issue.key}  [${f.status?.name}]  ${f.summary}`);
        lines.push(`  Type: ${f.issuetype?.name ?? "—"}  Priority: ${f.priority?.name ?? "—"}  Assignee: ${f.assignee?.displayName ?? "Unassigned"}`);
        lines.push(`  🔗 ${JIRA_BASE_URL}/browse/${issue.key}`);
        lines.push(``);
    }

    if (total > issues.length) {
        lines.push(`─────────────────────────────────────────`);
        lines.push(`⚠️  ${total - issues.length} more issues not shown. Refine your query or increase maxResults.`);
    }

    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

// ── MCP Server ────────────────────────────────────────────────────────────────

const server = new McpServer({
    name: "jira",
    version: "1.0.0"
});

// ── Tool: get_issue ───────────────────────────────────────────────────────────

server.tool(
    "get_issue",
    "Fetch a Jira issue by key, including its full description, metadata, linked issues, and comments.",
    { key: z.string().describe("The Jira issue key, e.g. XYZ-123") },
    async ({ key }) => {
        try {
            const issueKey = key.trim().toUpperCase();

            const { status, ok, data: issue } = await jiraGet(`/issue/${issueKey}`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check JIRA_PAT.` }] };
            }
            if (status === 404) {
                return { content: [{ type: "text", text: `Issue ${issueKey} not found.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error fetching ${issueKey}: HTTP ${status}` }] };
            }

            const { data: commentsData } = await jiraGet(`/issue/${issueKey}/comment`);
            const comments = commentsData?.comments ?? [];

            return {
                content: [{ type: "text", text: formatIssue(issue, comments) }]
            };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: search ──────────────────────────────────────────────────────────────

server.tool(
    "search",
    "Search Jira issues using JQL (Jira Query Language). Returns a list of matching issues with key, summary, status, type, priority and assignee.",
    {
        jql:        z.string().describe("JQL query string, e.g. 'project = VAE AND issuetype = Bug AND status = Open'"),
        maxResults: z.number().optional().default(20).describe("Maximum number of results to return (default 20, max 50)")
    },
    async ({ jql, maxResults = 20 }) => {
        try {
            const params = new URLSearchParams({
                jql,
                maxResults: Math.min(maxResults, 50),
                fields: "summary,status,issuetype,priority,assignee,reporter,created"
            });

            const { status, ok, data } = await jiraGet(`/search?${params}`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check JIRA_PAT.` }] };
            }
            if (status === 400) {
                return { content: [{ type: "text", text: `Invalid JQL query: ${jql}\nCheck your query syntax and try again.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error running search: HTTP ${status}` }] };
            }

            return {
                content: [{ type: "text", text: formatSearchResults(data.issues ?? [], jql, data.total ?? 0) }]
            };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_current_user ────────────────────────────────────────────────────

server.tool(
    "get_current_user",
    "Returns the currently authenticated Jira user. Call this first whenever you need the current user's username or accountId, for example before searching for issues assigned to the current user.",
    {},
    async () => {
        try {
            const { status, ok, data } = await jiraGet("/myself");

            if (!ok) {
                return { content: [{ type: "text", text: `Failed to get current user: HTTP ${status}` }] };
            }

            return {
                content: [{ type: "text", text: `Current Jira user: ${data.displayName} (username: ${data.name}, email: ${data.emailAddress})` }]
            };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Start ─────────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);