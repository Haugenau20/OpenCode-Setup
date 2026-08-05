import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { makeDispatcher, requireEnv, bearerAuth, jsonGet, jsonSend, toolError } from "../_lib/common.js";

// ── Config ────────────────────────────────────────────────────────────────────

// Canonical .env names, passed through by docker compose env_file and inherited
// by whatever process spawns this server. Confluence Data Center authenticates
// the PAT as a Bearer token (same as Jira DC) — not Basic — so no username is
// needed. CONFLUENCE_BASE_URL must include the port if Confluence is served on
// its default 8090 connector (e.g. http://confluence.internal.example:8090).
requireEnv(["CONFLUENCE_BASE_URL", "CONFLUENCE_PAT"]);
const CONFLUENCE_BASE_URL = process.env.CONFLUENCE_BASE_URL;
const CONFLUENCE_PAT      = process.env.CONFLUENCE_PAT;

// Write gate. Mirrors ALLOW_REMOTE_GIT: default OFF, and only the exact string
// "1" turns it on, so a typo, "true", or an empty value all leave the server
// read-only. When off, the write tools are never REGISTERED — the model does
// not see them at all, which is stronger than refusing at call time (nothing to
// argue with, nothing to retry) and keeps the tool list honest about what this
// server can currently do.
//
// The variable is read once at boot: the env is fixed for the process's
// lifetime, and re-reading per call would only invite the illusion that the
// gate can be flipped without a restart. It cannot — change .env and restart.
const ALLOW_WRITE = process.env.ALLOW_CONFLUENCE_WRITE === "1";

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

async function confluenceSend(method, path, body) {
    return jsonSend(method, `${CONFLUENCE_BASE_URL}/rest/api${path}`, confluenceHeaders(), body, dispatcher);
}

// Shared failure rendering for the write tools. Confluence answers a rejected
// write with a 400 whose body is the only thing that says WHY, so the server's
// own message is always surfaced (see jsonSend/errorText) rather than being
// flattened into a bare status code.
function writeFailure(action, { status, error }) {
    const detail = error ? `\n${error}` : "";
    if (status === 401 || status === 403) {
        return `Not permitted to ${action} (HTTP ${status}). The PAT authenticated but may lack write permission in this space — check CONFLUENCE_PAT's account has "Add/Edit page" rights.${detail}`;
    }
    if (status === 404) {
        return `Cannot ${action}: the target space, parent, or page does not exist (HTTP 404).${detail}`;
    }
    if (status === 409) {
        return `Conflict while trying to ${action} (HTTP 409). The page was modified by someone else since it was read — re-read it with get_page and retry.${detail}`;
    }
    if (status === 400) {
        return `Confluence rejected the request to ${action} (HTTP 400).${detail}\nCommon causes: a page with that title already exists in the space, or the body is not well-formed storage-format XHTML (every tag must be closed, & must be &amp;).`;
    }
    return `Unexpected error trying to ${action}: HTTP ${status}${detail}`;
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

// Confluence only accepts storage format on writes. `wiki` is offered as the
// ergonomic alternative — Confluence's own lightweight markup (`h1. Title`,
// `* bullet`, `{code}`), far easier to write correctly than raw XHTML — and is
// converted server-side by Confluence itself, so the result is exactly what
// Confluence would have produced from the same markup in its editor.
// Deliberately NOT markdown: the DC converter has no markdown representation,
// and a hand-rolled markdown→XHTML pass here would silently mangle anything it
// did not implement.
async function toStorage(value, format) {
    if (format !== "wiki") return { ok: true, value };

    const { status, ok, data, error } = await confluenceSend(
        "POST",
        "/contentbody/convert/storage",
        { value, representation: "wiki" }
    );
    if (!ok) {
        const detail = error ? `\n${error}` : "";
        return {
            ok: false,
            message: `Failed to convert wiki markup to storage format (HTTP ${status}).${detail}\nRewrite the body as storage-format XHTML and pass format="storage" instead.`
        };
    }
    return { ok: true, value: data?.value ?? "" };
}

function formatWriteResult(verb, content) {
    return [
        `✅  ${verb}: ${content.title}`,
        `🔗  ${pageUrl(content)}`,
        `─────────────────────────────────────────`,
        `ID:        ${content.id}`,
        `Type:      ${content.type ?? "—"}`,
        `Space:     ${content.space?.key ?? "—"}`,
        `Version:   ${content.version?.number ?? "—"}`,
        `─────────────────────────────────────────`
    ].join("\n");
}

function formatPage(content, format = "text") {
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
    // format="storage" returns the body verbatim. The stripped rendering below
    // is lossy by design and cannot be edited and written back — anything that
    // intends to MODIFY a page needs the exact markup it is about to replace.
    if (format === "storage") {
        lines.push(`📋 CONTENT (raw storage format)`);
        lines.push(body || "(empty page)");
    } else {
        lines.push(`📋 CONTENT`);
        lines.push(stripStorageFormat(body));
    }
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
        title:    z.string().optional().describe("Exact page title (use together with spaceKey)"),
        format:   z.enum(["text", "storage"]).optional().default("text").describe("'text' (default) renders the body as readable plain text; 'storage' returns the raw storage-format XHTML — use it when you are about to edit the page, since the text rendering is lossy and cannot be written back")
    },
    async ({ id, spaceKey, title, format = "text" }) => {
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

            return { content: [{ type: "text", text: formatPage(content, format) }] };

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

// ── Write tools (ALLOW_CONFLUENCE_WRITE=1 only) ───────────────────────────────
// Everything below this line mutates Confluence. The whole block is skipped
// when the gate is off, so on a default install the server advertises exactly
// the five read tools above and there is no write surface to reach.
//
// Deliberately NOT implemented, gate or no gate: deleting pages, deleting
// spaces, and editing other people's comments. Creating and editing is
// recoverable — every Confluence page keeps full version history, and a bad
// edit is one "Restore this version" click away — whereas a deletion an agent
// made on its own initiative is not obviously recoverable by the person who
// has to clean it up. If you need a page gone, delete it in the browser.

if (ALLOW_WRITE) {

    // ── Tool: create_page ─────────────────────────────────────────────────────

    server.tool(
        "create_page",
        "Create a new Confluence page in a space, optionally nested under a parent page. Requires write access to be enabled on this server.",
        {
            spaceKey: z.string().describe("Key of the space to create the page in, e.g. 'ENG'"),
            title:    z.string().describe("Page title. Must be unique within the space — Confluence rejects a duplicate title with a 400."),
            body:     z.string().describe("Page body, in the format given by `format`"),
            format:   z.enum(["storage", "wiki"]).optional().default("storage").describe("'storage' (default) = Confluence storage-format XHTML, e.g. <h1>Title</h1><p>text</p>. 'wiki' = Confluence wiki markup, e.g. 'h1. Title' — easier to write by hand; Confluence converts it server-side."),
            parentId: z.string().optional().describe("Numeric id of the parent page. Omit to create the page at the space root.")
        },
        async ({ spaceKey, title, body, format = "storage", parentId }) => {
            try {
                const converted = await toStorage(body, format);
                if (!converted.ok) {
                    return { content: [{ type: "text", text: converted.message }] };
                }

                const payload = {
                    type: "page",
                    title,
                    space: { key: spaceKey },
                    body: { storage: { value: converted.value, representation: "storage" } }
                };
                if (parentId) payload.ancestors = [{ id: parentId.trim() }];

                const res = await confluenceSend("POST", "/content?expand=version,space", payload);
                if (!res.ok) {
                    return { content: [{ type: "text", text: writeFailure(`create page "${title}" in space ${spaceKey}`, res) }] };
                }

                return { content: [{ type: "text", text: formatWriteResult("Created page", res.data) }] };

            } catch (err) {
                return toolError(err, { prefix: "MCP error", includeCause: true });
            }
        }
    );

    // ── Tool: update_page ─────────────────────────────────────────────────────

    server.tool(
        "update_page",
        "Replace the body and/or title of an existing Confluence page. The previous content stays in the page's version history. Read the page with get_page(format='storage') first if you intend to preserve any of the existing content.",
        {
            id:      z.string().describe("Numeric id of the page to update"),
            body:    z.string().optional().describe("New page body, in the format given by `format`. REPLACES the existing body entirely — omit to change only the title, or use append_to_page to add to the end instead."),
            title:   z.string().optional().describe("New page title. Omit to keep the current title."),
            format:  z.enum(["storage", "wiki"]).optional().default("storage").describe("Format of `body`: 'storage' (Confluence storage-format XHTML, default) or 'wiki' (Confluence wiki markup)"),
            versionComment: z.string().optional().describe("Short note describing the change, shown in the page's version history")
        },
        async ({ id, body, title, format = "storage", versionComment }) => {
            try {
                if (body === undefined && title === undefined) {
                    return { content: [{ type: "text", text: "Nothing to update: provide body, title, or both." }] };
                }

                const current = await fetchForUpdate(id);
                if (!current.ok) return { content: [{ type: "text", text: current.message }] };

                let storage = current.page.body?.storage?.value ?? "";
                if (body !== undefined) {
                    const converted = await toStorage(body, format);
                    if (!converted.ok) return { content: [{ type: "text", text: converted.message }] };
                    storage = converted.value;
                }

                const res = await putPage(current.page, storage, title, versionComment);
                if (!res.ok) {
                    return { content: [{ type: "text", text: writeFailure(`update page ${id}`, res) }] };
                }

                return { content: [{ type: "text", text: formatWriteResult("Updated page", res.data) }] };

            } catch (err) {
                return toolError(err, { prefix: "MCP error", includeCause: true });
            }
        }
    );

    // ── Tool: append_to_page ──────────────────────────────────────────────────

    server.tool(
        "append_to_page",
        "Append content to the end of an existing Confluence page, keeping everything already on it. Use this to add a section rather than update_page, which replaces the whole body.",
        {
            id:     z.string().describe("Numeric id of the page to append to"),
            body:   z.string().describe("Content to add at the end of the page, in the format given by `format`"),
            format: z.enum(["storage", "wiki"]).optional().default("storage").describe("Format of `body`: 'storage' (Confluence storage-format XHTML, default) or 'wiki' (Confluence wiki markup)"),
            versionComment: z.string().optional().describe("Short note describing the change, shown in the page's version history")
        },
        async ({ id, body, format = "storage", versionComment }) => {
            try {
                const current = await fetchForUpdate(id);
                if (!current.ok) return { content: [{ type: "text", text: current.message }] };

                const converted = await toStorage(body, format);
                if (!converted.ok) return { content: [{ type: "text", text: converted.message }] };

                // Concatenating storage format is safe: it is a flat XHTML
                // fragment, not a document with a single root element, so a
                // well-formed addition after a well-formed body is itself
                // well-formed.
                const existing = current.page.body?.storage?.value ?? "";
                const merged = existing ? `${existing}\n${converted.value}` : converted.value;

                const res = await putPage(current.page, merged, undefined, versionComment ?? "Appended content");
                if (!res.ok) {
                    return { content: [{ type: "text", text: writeFailure(`append to page ${id}`, res) }] };
                }

                return { content: [{ type: "text", text: formatWriteResult("Appended to page", res.data) }] };

            } catch (err) {
                return toolError(err, { prefix: "MCP error", includeCause: true });
            }
        }
    );

    // ── Tool: add_comment ─────────────────────────────────────────────────────

    server.tool(
        "add_comment",
        "Post a comment on a Confluence page.",
        {
            id:     z.string().describe("Numeric id of the page to comment on"),
            body:   z.string().describe("Comment text, in the format given by `format`"),
            format: z.enum(["storage", "wiki"]).optional().default("storage").describe("Format of `body`: 'storage' (Confluence storage-format XHTML, default) or 'wiki' (Confluence wiki markup)")
        },
        async ({ id, body, format = "storage" }) => {
            try {
                const converted = await toStorage(body, format);
                if (!converted.ok) return { content: [{ type: "text", text: converted.message }] };

                const res = await confluenceSend("POST", "/content?expand=version,space", {
                    type: "comment",
                    container: { id: id.trim(), type: "page" },
                    body: { storage: { value: converted.value, representation: "storage" } }
                });
                if (!res.ok) {
                    return { content: [{ type: "text", text: writeFailure(`comment on page ${id}`, res) }] };
                }

                return { content: [{ type: "text", text: `✅  Comment added to page ${id}\n🔗  ${pageUrl(res.data)}` }] };

            } catch (err) {
                return toolError(err, { prefix: "MCP error", includeCause: true });
            }
        }
    );

} else {
    // Visible in the container logs, so "why can't the agent write?" is
    // answered without reading this file.
    console.error("confluence MCP: read-only (set ALLOW_CONFLUENCE_WRITE=1 in .env and restart to enable writes)");
}

// ── Write helpers ─────────────────────────────────────────────────────────────

// Confluence has no partial update: a PUT must carry the page's type, title,
// full body, and the NEXT version number, and it rejects the write outright if
// that number is not exactly current+1. So every edit is read-then-write, and
// both steps live here rather than being duplicated per tool.
async function fetchForUpdate(id) {
    const { status, ok, data } = await confluenceGet(
        `/content/${encodeURIComponent(id.trim())}?expand=body.storage,version,space`
    );
    if (status === 401 || status === 403) {
        return { ok: false, message: `Authentication failed (${status}). Check CONFLUENCE_PAT.` };
    }
    if (status === 404) {
        return { ok: false, message: `Page ${id} not found — nothing was changed.` };
    }
    if (!ok) {
        return { ok: false, message: `Could not read page ${id} before writing (HTTP ${status}) — nothing was changed.` };
    }
    return { ok: true, page: data };
}

async function putPage(page, storageValue, newTitle, versionComment) {
    const payload = {
        id: page.id,
        type: page.type ?? "page",
        title: newTitle ?? page.title,
        body: { storage: { value: storageValue, representation: "storage" } },
        version: {
            number: (page.version?.number ?? 0) + 1,
            ...(versionComment ? { message: versionComment } : {})
        }
    };
    // The space is required by some DC versions when the title changes; sending
    // it always is harmless and avoids a title-only edit failing on a 400.
    if (page.space?.key) payload.space = { key: page.space.key };

    return confluenceSend("PUT", `/content/${encodeURIComponent(page.id)}?expand=version,space`, payload);
}

// ── Start ─────────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
