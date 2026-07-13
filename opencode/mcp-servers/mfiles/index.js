import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { fetch as undiciFetch } from "undici";
import { makeDispatcher, requireEnv, xAuthenticationAuth, jsonGet, toolError } from "../_lib/common.js";

// ── Config ────────────────────────────────────────────────────────────────────

// Canonical .env names, passed through by docker compose env_file and inherited
// by whatever process spawns this server. M-Files' Web Service REST API does
// NOT use Authorization/Bearer or Basic — it authenticates the PAT via a custom
// `X-Authentication` header — so no username is needed. MFILES_BASE_URL is the
// site base; the server appends /REST itself (mirrors Jira's /rest/api/2 and
// Confluence's /rest/api).
requireEnv(["MFILES_BASE_URL", "MFILES_PAT"]);
const MFILES_BASE_URL = process.env.MFILES_BASE_URL.replace(/\/$/, "");
const MFILES_PAT      = process.env.MFILES_PAT;

// TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in policy.yaml).
// Do NOT re-add rejectUnauthorized:false — a locked-down image must not skip
// certificate verification. If a TLS M-Files fails here, the CA isn't in the
// baked bundle; fix the CA, don't disable the check.
const dispatcher = makeDispatcher();

// ── Helpers ───────────────────────────────────────────────────────────────────

function mfHeaders() {
    return {
        "X-Authentication": xAuthenticationAuth(MFILES_PAT),
        "Accept": "application/json"
    };
}

async function mfGet(path) {
    return jsonGet(`${MFILES_BASE_URL}/REST${path}`, mfHeaders(), dispatcher);
}

function formatObjectTypes(types) {
    if (!types?.length) return "No object types found.";
    const lines = [
        `🗂️  Object types (${types.length})`,
        `─────────────────────────────────────────`,
    ];
    for (const t of types) {
        // NOTE: assuming .ID / .Name / .NamePlural per the M-Files structure/objecttypes shape.
        lines.push(`ID ${t?.ID ?? "—"}  ${t?.Name ?? "unknown"} (plural: ${t?.NamePlural ?? "—"})`);
    }
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatClasses(classes) {
    if (!classes?.length) return "No classes found.";
    const lines = [
        `🗃️  Classes (${classes.length})`,
        `─────────────────────────────────────────`,
    ];
    for (const c of classes) {
        // NOTE: assuming .ID / .Name / .ObjectType per the M-Files structure/classes shape.
        lines.push(`ID ${c?.ID ?? "—"}  ${c?.Name ?? "unknown"}  (object type: ${c?.ObjectType ?? "—"})`);
    }
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatSearchResults(items, query) {
    if (!items?.length) {
        return `No objects found for query: ${query}`;
    }

    const lines = [
        `🔍  Search results for: ${query}`,
        `    ${items.length} match${items.length === 1 ? "" : "es"}`,
        `─────────────────────────────────────────`,
    ];

    for (const item of items) {
        // NOTE: assuming .Title, .DisplayID and .ObjVer = { Type, ID, Version } per
        // the M-Files ObjectVersion shape returned by GET /REST/objects.
        const ov = item?.ObjVer;
        lines.push(`${item?.Title ?? "(untitled)"}  ${item?.DisplayID ? `[${item.DisplayID}]` : ""}`);
        lines.push(`  Type: ${ov?.Type ?? "—"}  ID: ${ov?.ID ?? "—"}  Version: ${ov?.Version ?? "—"}`);
        if (ov?.Type != null && ov?.ID != null) {
            lines.push(`  → get_object({ objectType: ${ov.Type}, objectId: ${ov.ID} })`);
        }
        lines.push(``);
    }

    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

function formatProperties(properties) {
    if (!properties?.length) return "(no properties)";
    const lines = [];
    for (const p of properties) {
        // NOTE: assuming each PropertyValue has .PropertyDef (a property def id) and
        // .TypedValue.DisplayValue per the M-Files PropertyValue shape.
        const name = p?.PropertyDef ?? "—";
        const value = p?.TypedValue?.DisplayValue ?? "—";
        lines.push(`  ${name}: ${value}`);
    }
    return lines.join("\n");
}

function formatObject(objVer, properties, files) {
    // NOTE: assuming ObjectVersion carries .Title, .ObjVer = { Type, ID, Version },
    // .DisplayID, .Class and an optional .Files array of { ID, Name, Extension }.
    const ov = objVer?.ObjVer;
    const lines = [
        `📄  ${objVer?.Title ?? "(untitled)"}`,
        `─────────────────────────────────────────`,
        `Type:       ${ov?.Type ?? "—"}`,
        `ID:         ${ov?.ID ?? "—"}`,
        `Version:    ${ov?.Version ?? "—"}`,
        `Display ID: ${objVer?.DisplayID ?? "—"}`,
        `Class:      ${objVer?.Class ?? "—"}`,
    ];

    lines.push(`─────────────────────────────────────────`);
    lines.push(`📋 PROPERTIES`);
    lines.push(formatProperties(properties));

    const fileList = files ?? objVer?.Files;
    lines.push(`─────────────────────────────────────────`);
    if (fileList?.length) {
        lines.push(`📎 FILES (${fileList.length})`);
        for (const f of fileList) {
            // NOTE: assuming each file entry has .ID, .Name, .Extension.
            lines.push(`  fileId ${f?.ID ?? "—"}: ${f?.Name ?? "unknown"}${f?.Extension ? `.${f.Extension}` : ""}`);
        }
        lines.push(`  → get_file_content({ objectType: ${ov?.Type ?? "?"}, objectId: ${ov?.ID ?? "?"}, fileId: <fileId> })`);
    } else {
        lines.push(`📎 FILES: (none)`);
    }
    lines.push(`─────────────────────────────────────────`);
    return lines.join("\n");
}

// ── MCP Server ────────────────────────────────────────────────────────────────

const server = new McpServer({
    name: "mfiles",
    version: "1.0.0"
});

// ── Tool: list_object_types ──────────────────────────────────────────────────

server.tool(
    "list_object_types",
    "List all M-Files object types (e.g. Document, Customer, Project) with their numeric IDs. Call this first to learn object type IDs before searching or fetching objects — search_objects and get_object both take an object type id.",
    {},
    async () => {
        try {
            const { status, ok, data } = await mfGet("/structure/objecttypes");

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check MFILES_PAT.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error listing object types: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatObjectTypes(data) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: list_classes ───────────────────────────────────────────────────────

server.tool(
    "list_classes",
    "List all M-Files object classes (e.g. Invoice, Contract, Meeting Minutes) with their numeric IDs and the object type each belongs to. Useful for understanding how objects are categorized before a scoped search.",
    {},
    async () => {
        try {
            const { status, ok, data } = await mfGet("/structure/classes");

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check MFILES_PAT.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error listing classes: HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatClasses(data) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: search_objects ─────────────────────────────────────────────────────

server.tool(
    "search_objects",
    "Quick text search across M-Files objects. Optionally restrict to a single object type (use list_object_types to learn the id first). Returns title, object type, id and version for each match.",
    {
        query:      z.string().describe("Free-text search query"),
        objectType: z.number().optional().describe("Restrict results to this object type id (see list_object_types)"),
        limit:      z.number().optional().default(20).describe("Maximum number of results to return (default 20, max 50)")
    },
    async ({ query, objectType, limit = 20 }) => {
        try {
            // NOTE: `q` (search text) and `o` (object type filter) are inferred quick-search
            // param names for GET /REST/objects; verify against the live API.
            const params = new URLSearchParams({ q: query, limit: String(Math.min(limit, 50)) });
            if (objectType !== undefined) params.set("o", String(objectType));

            const { status, ok, data } = await mfGet(`/objects?${params}`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check MFILES_PAT.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error running search: HTTP ${status}` }] };
            }

            // NOTE: assuming the response is an object with an .Items array of ObjectVersion.
            return { content: [{ type: "text", text: formatSearchResults(data?.Items ?? [], query) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_object ─────────────────────────────────────────────────────────

server.tool(
    "get_object",
    "Fetch a single M-Files object (latest version) by object type and object id, including its properties and any attached files. Use search_objects or list_object_types first to find the object type/id.",
    {
        objectType: z.number().describe("The object type id (see list_object_types)"),
        objectId:   z.number().describe("The numeric object id")
    },
    async ({ objectType, objectId }) => {
        try {
            const { status, ok, data: objVer } = await mfGet(`/objects/${objectType}/${objectId}/latest`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check MFILES_PAT.` }] };
            }
            if (status === 404) {
                return { content: [{ type: "text", text: `Object (type ${objectType}, id ${objectId}) not found.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error fetching object (type ${objectType}, id ${objectId}): HTTP ${status}` }] };
            }

            const { data: properties } = await mfGet(`/objects/${objectType}/${objectId}/latest/properties`);

            return { content: [{ type: "text", text: formatObject(objVer, properties ?? [], objVer?.Files) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_object_properties ──────────────────────────────────────────────

server.tool(
    "get_object_properties",
    "Fetch just the property values of an M-Files object's latest version — a lighter-weight companion to get_object when you only need metadata, not the full object summary and file list.",
    {
        objectType: z.number().describe("The object type id (see list_object_types)"),
        objectId:   z.number().describe("The numeric object id")
    },
    async ({ objectType, objectId }) => {
        try {
            const { status, ok, data } = await mfGet(`/objects/${objectType}/${objectId}/latest/properties`);

            if (status === 401 || status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${status}). Check MFILES_PAT.` }] };
            }
            if (status === 404) {
                return { content: [{ type: "text", text: `Object (type ${objectType}, id ${objectId}) not found.` }] };
            }
            if (!ok) {
                return { content: [{ type: "text", text: `Unexpected error fetching properties for (type ${objectType}, id ${objectId}): HTTP ${status}` }] };
            }

            return { content: [{ type: "text", text: formatProperties(data ?? []) }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Tool: get_file_content ───────────────────────────────────────────────────

server.tool(
    "get_file_content",
    "Download the content of a specific file attached to an M-Files object. Use get_object first to list the file ids available on an object. Text files are returned inline; binary files are reported as binary (with size) rather than dumped.",
    {
        objectType: z.number().describe("The object type id (see list_object_types)"),
        objectId:   z.number().describe("The numeric object id"),
        fileId:     z.number().describe("The file id, from the Files list on get_object's output"),
        version:    z.string().optional().default("latest").describe("Object version to read the file from (default \"latest\")")
    },
    async ({ objectType, objectId, fileId, version = "latest" }) => {
        try {
            const url = `${MFILES_BASE_URL}/REST/objects/${objectType}/${objectId}/${version}/files/${fileId}/content`;
            const res = await undiciFetch(url, { headers: mfHeaders(), dispatcher });

            if (res.status === 401 || res.status === 403) {
                return { content: [{ type: "text", text: `Authentication failed (${res.status}). Check MFILES_PAT.` }] };
            }
            if (res.status === 404) {
                return { content: [{ type: "text", text: `File ${fileId} on object (type ${objectType}, id ${objectId}) not found.` }] };
            }
            if (!res.ok) {
                return { content: [{ type: "text", text: `Unexpected error fetching file ${fileId}: HTTP ${res.status}` }] };
            }

            const buf = Buffer.from(await res.arrayBuffer());

            // Same text-vs-binary heuristic as GitLab's get_file: treat as binary if the
            // decoded buffer contains a NUL byte, rather than dumping raw bytes.
            if (buf.includes(0)) {
                return { content: [{ type: "text", text: `File ${fileId} is binary (${buf.length} bytes) — not displayed inline.` }] };
            }

            return { content: [{ type: "text", text: buf.toString("utf8") }] };

        } catch (err) {
            return toolError(err, { prefix: "MCP error", includeCause: true });
        }
    }
);

// ── Start ─────────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
