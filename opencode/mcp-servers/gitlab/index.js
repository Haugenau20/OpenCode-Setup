#!/usr/bin/env node
/**
 * GitLab MCP Server
 *
 * Provides read-only access to an internal GitLab instance.
 * Designed to run inside a Docker container that routes all traffic
 * through a Squid proxy — uses undici with ProxyAgent for all HTTP calls.
 *
 * Tools:
 *   list_projects        — discover/search accessible GitLab projects
 *   get_commits           — recent commits for a project (optionally filtered)
 *   get_merge_requests     — list open/merged/closed MRs for a project
 *   get_merge_request      — single MR with notes/comments
 *   get_mr_changes          — list files changed in an MR
 *   get_mr_diff             — full unified diff of an MR
 *   get_file               — file contents at a given ref
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
    CallToolRequestSchema,
    ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { fetch } from "undici";
import { z } from "zod";
import { makeDispatcher, requireEnv, privateTokenAuth, toolError } from "../_lib/common.js";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

// Read the canonical .env names directly. docker compose passes these through
// env_file, so they're in the container environment and inherited by whatever
// process opencode spawns this server from (backend OR the TUI's docker exec) —
// unlike a var only export-ed at runtime by PID 1. GITLAB_USER is only needed
// for git over HTTPS, not the REST API, so it isn't required for the server
// to start, but we still read it in case callers want it surfaced later.
requireEnv(["GITLAB_BASE_URL", "GITLAB_PAT"]);
const GITLAB_BASE_URL = process.env.GITLAB_BASE_URL?.replace(/\/$/, "");
const GITLAB_USER = process.env.GITLAB_USER;
const GITLAB_PAT = process.env.GITLAB_PAT;

// TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in policy.yaml).
// Do NOT re-add rejectUnauthorized:false — a locked-down image must not skip
// certificate verification. If TLS to GitLab fails here, the CA isn't in the
// baked bundle; fix the CA, don't disable the check.
const proxyAgent = makeDispatcher();

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

/**
 * Fetch a GitLab REST API endpoint and return parsed JSON.
 * Throws a descriptive error on non-2xx responses.
 */
async function glFetch(path, params = {}) {
    const url = new URL(`${GITLAB_BASE_URL}/api/v4${path}`);

    for (const [k, v] of Object.entries(params)) {
        if (v !== undefined && v !== null && v !== "") {
            url.searchParams.set(k, String(v));
        }
    }

    const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
            "PRIVATE-TOKEN": privateTokenAuth(GITLAB_PAT),
            Accept: "application/json",
        },
        dispatcher: proxyAgent,
    });

    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(
            `GitLab API error ${response.status} for ${url.pathname}: ${body}`
        );
    }

    return response.json();
}

/**
 * Paginate through all pages of a GitLab list endpoint.
 * GitLab uses ?per_page=&page= pagination — keep requesting pages until one
 * comes back short of per_page (i.e. the last page) or we hit maxItems.
 */
async function glFetchAll(path, params = {}, maxItems = 200) {
    const items = [];
    let page = 1;
    const perPage = 100;

    while (items.length < maxItems) {
        const data = await glFetch(path, { ...params, per_page: perPage, page });
        const batch = Array.isArray(data) ? data : [];
        items.push(...batch);

        if (batch.length < perPage) break;
        page += 1;
    }

    return items;
}

/**
 * URL-encode a GitLab project identifier. Accepts either a numeric ID or a
 * "namespace/path" string — GitLab requires the latter to be percent-encoded
 * as a single path segment (e.g. "group/sub/repo" -> "group%2Fsub%2Frepo").
 */
function encodeProjectId(project) {
    return encodeURIComponent(String(project));
}

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

const ListProjectsSchema = z.object({
    search: z.string().optional().describe("Search term to filter projects by name/path"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .default(50)
        .describe("Max projects to return (default 50)"),
});

const ProjectArg = {
    project: z
        .string()
        .describe(
            "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)"
        ),
};

const GetCommitsSchema = z.object({
    ...ProjectArg,
    ref: z
        .string()
        .optional()
        .describe("Branch, tag, or commit SHA to list commits from (default: default branch)"),
    query: z
        .string()
        .optional()
        .describe(
            "Filter commits whose message contains this string (e.g. a Jira ticket key)"
        ),
    limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .default(30)
        .describe("Max commits to return (default 30)"),
});

const GetMergeRequestsSchema = z.object({
    ...ProjectArg,
    state: z
        .enum(["opened", "merged", "closed", "all"])
        .default("opened")
        .describe("MR state filter (default opened)"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(50)
        .default(20)
        .describe("Max MRs to return (default 20)"),
});

const GetMergeRequestSchema = z.object({
    ...ProjectArg,
    mrIid: z.number().int().describe("Merge request internal ID (iid)"),
});

const GetMrChangesSchema = z.object({
    ...ProjectArg,
    mrIid: z.number().int().describe("Merge request internal ID (iid)"),
});

const GetMrDiffSchema = z.object({
    ...ProjectArg,
    mrIid: z.number().int().describe("Merge request internal ID (iid)"),
});

const GetFileSchema = z.object({
    ...ProjectArg,
    filePath: z
        .string()
        .describe("Path to the file within the repository (e.g. src/main/App.java)"),
    ref: z
        .string()
        .optional()
        .describe("Branch, tag, or commit hash (default: default branch)"),
});

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

async function listProjects(args) {
    const { search, limit } = ListProjectsSchema.parse(args ?? {});

    const params = { membership: true, simple: true };
    if (search) params.search = search;

    const projects = await glFetchAll(`/projects`, params, limit);

    return {
        count: Math.min(projects.length, limit),
        projects: projects.slice(0, limit).map((p) => ({
            id: p.id,
            path_with_namespace: p.path_with_namespace,
            name: p.name,
            description: p.description ?? null,
            default_branch: p.default_branch ?? null,
            web_url: p.web_url ?? null,
        })),
    };
}

async function getCommits(args) {
    const { project, ref, query, limit } = GetCommitsSchema.parse(args);

    const params = {};
    if (ref) params.ref_name = ref;
    // GitLab's commits endpoint doesn't support message search, so we fetch
    // more and filter client-side when a query is provided.
    const fetchLimit = query ? Math.min(limit * 5, 200) : limit;

    const commits = await glFetchAll(
        `/projects/${encodeProjectId(project)}/repository/commits`,
        params,
        fetchLimit
    );

    // Use word-boundary regex so "VAE-33" doesn't match "VAE-331".
    // Falls back to plain includes if the query isn't a valid regex.
    let queryRe = null;
    if (query) {
        try {
            queryRe = new RegExp(`(?<![\\w-])${query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\w-])`, "i");
        } catch {
            queryRe = null;
        }
    }

    const filtered = query
        ? commits.filter((c) =>
            queryRe
                ? queryRe.test(c.message ?? c.title ?? "")
                : (c.message ?? c.title ?? "").toLowerCase().includes(query.toLowerCase())
        )
        : commits;

    const results = filtered.slice(0, limit).map((c) => ({
        id: c.id,
        short_id: c.short_id,
        message: c.title ?? c.message,
        author_name: c.author_name ?? "unknown",
        created_at: c.created_at ?? null,
        parent_ids: c.parent_ids ?? [],
    }));

    return {
        project,
        ref: ref ?? "(default)",
        query: query ?? null,
        count: results.length,
        commits: results,
    };
}

async function getMergeRequests(args) {
    const { project, state, limit } = GetMergeRequestsSchema.parse(args);

    const mrs = await glFetchAll(
        `/projects/${encodeProjectId(project)}/merge_requests`,
        { state },
        limit
    );

    const results = mrs.slice(0, limit).map((mr) => ({
        iid: mr.iid,
        title: mr.title,
        state: mr.state,
        author: mr.author?.username ?? mr.author?.name ?? "unknown",
        source_branch: mr.source_branch ?? null,
        target_branch: mr.target_branch ?? null,
        web_url: mr.web_url ?? null,
        created_at: mr.created_at ?? null,
        updated_at: mr.updated_at ?? null,
        description: mr.description ? mr.description.slice(0, 280) : null,
    }));

    return {
        project,
        state,
        count: results.length,
        mergeRequests: results,
    };
}

async function getMergeRequest(args) {
    const { project, mrIid } = GetMergeRequestSchema.parse(args);

    const basePath = `/projects/${encodeProjectId(project)}/merge_requests/${mrIid}`;

    const [mr, notes] = await Promise.all([
        glFetch(basePath),
        glFetchAll(`${basePath}/notes`, {}, 200),
    ]);

    // Filter out system-generated notes (e.g. "changed target branch", "added 3 commits")
    // and keep only real user comments.
    const comments = notes
        .filter((n) => !n.system)
        .map((n) => ({
            author: n.author?.username ?? n.author?.name ?? "unknown",
            body: n.body ?? "",
            created_at: n.created_at ?? null,
        }));

    return {
        iid: mr.iid,
        title: mr.title,
        state: mr.state,
        description: mr.description ?? null,
        author: mr.author?.username ?? mr.author?.name ?? "unknown",
        source_branch: mr.source_branch ?? null,
        source_sha: mr.diff_refs?.head_sha ?? mr.sha ?? null,
        target_branch: mr.target_branch ?? null,
        target_sha: mr.diff_refs?.base_sha ?? null,
        reviewers: (mr.reviewers ?? []).map((r) => r.username ?? r.name),
        assignees: (mr.assignees ?? []).map((a) => a.username ?? a.name),
        web_url: mr.web_url ?? null,
        created_at: mr.created_at ?? null,
        updated_at: mr.updated_at ?? null,
        comments,
    };
}

async function getMrChanges(args) {
    const { project, mrIid } = GetMrChangesSchema.parse(args);

    const basePath = `/projects/${encodeProjectId(project)}/merge_requests/${mrIid}`;
    const data = await glFetch(`${basePath}/changes`);

    const files = (data.changes ?? []).map((c) => {
        let type = "MODIFY";
        if (c.new_file) type = "ADD";
        else if (c.deleted_file) type = "DELETE";
        else if (c.renamed_file) type = "RENAME";

        return {
            path: c.new_path,
            oldPath: c.old_path,
            type,
        };
    });

    return {
        project,
        mrIid,
        count: files.length,
        files,
    };
}

async function getMrDiff(args) {
    const { project, mrIid } = GetMrDiffSchema.parse(args);

    const basePath = `/projects/${encodeProjectId(project)}/merge_requests/${mrIid}`;
    const data = await glFetch(`${basePath}/changes`);

    const sections = (data.changes ?? []).map((c) => {
        const fromPath = c.old_path ?? "/dev/null";
        const toPath = c.new_path ?? "/dev/null";
        const header = `--- a/${fromPath}\n+++ b/${toPath}`;
        return [header, c.diff ?? ""].join("\n");
    });

    return {
        project,
        mrIid,
        diff: sections.join("\n\n"),
    };
}

async function getFile(args) {
    const { project, filePath, ref } = GetFileSchema.parse(args);

    const params = {};
    if (ref) params.ref = ref;

    const encodedPath = encodeURIComponent(filePath);

    let data;
    try {
        data = await glFetch(
            `/projects/${encodeProjectId(project)}/repository/files/${encodedPath}`,
            params
        );
    } catch (err) {
        if (/error 404/i.test(err.message)) {
            return {
                project,
                path: filePath,
                ref: ref ?? "(default)",
                found: false,
                content: null,
            };
        }
        throw err;
    }

    let content = null;
    let binary = false;
    if (data.encoding === "base64" && typeof data.content === "string") {
        const buf = Buffer.from(data.content, "base64");
        // Heuristic: treat as binary if it contains a NUL byte once decoded.
        if (buf.includes(0)) {
            binary = true;
        } else {
            content = buf.toString("utf8");
        }
    } else {
        content = data.content ?? null;
    }

    return {
        project,
        path: filePath,
        ref: ref ?? "(default)",
        found: true,
        binary,
        content,
    };
}

// ---------------------------------------------------------------------------
// MCP server setup
// ---------------------------------------------------------------------------

const server = new Server(
    { name: "gitlab", version: "1.0.0" },
    { capabilities: { tools: {} } }
);

const TOOLS = [
    {
        name: "list_projects",
        description:
            "Discover GitLab projects accessible to the current user, optionally filtered by a search term. " +
            "Call this first when you don't know a project's numeric ID or namespace/path — it returns the " +
            "id, path_with_namespace, name, description, default_branch, and web_url for each match.",
        inputSchema: {
            type: "object",
            properties: {
                search: { type: "string", description: "Search term to filter projects by name/path" },
                limit: { type: "number", description: "Max projects to return (default 50)" },
            },
            required: [],
        },
    },
    {
        name: "get_commits",
        description:
            "Fetch recent commits for a GitLab project. " +
            "Optionally filter by ref (branch/tag/SHA) and/or a search string in the commit message (e.g. a Jira ticket key). " +
            "Useful for finding when a change was made or which commit introduced an issue.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                ref: { type: "string", description: "Branch, tag, or commit SHA to list commits from (default: default branch)" },
                query: { type: "string", description: "Filter commits whose message contains this string (e.g. a Jira ticket key like PROJ-123)" },
                limit: { type: "number", description: "Max commits to return (default 30, max 100)" },
            },
            required: ["project"],
        },
    },
    {
        name: "get_merge_requests",
        description:
            "List merge requests for a GitLab project. " +
            "Returns iid, title, author, status, branches, and description. " +
            "Use state=merged to find which MR delivered a feature.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                state: {
                    type: "string",
                    enum: ["opened", "merged", "closed", "all"],
                    description: "MR state filter (default opened)",
                },
                limit: { type: "number", description: "Max MRs to return (default 20, max 50)" },
            },
            required: ["project"],
        },
    },
    {
        name: "get_merge_request",
        description:
            "Fetch a single merge request by iid, including its full description and review comments. " +
            "Use this after get_merge_requests to deep-dive into a specific MR.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                mrIid: { type: "number", description: "Merge request internal ID (iid)" },
            },
            required: ["project", "mrIid"],
        },
    },
    {
        name: "get_mr_changes",
        description:
            "List all files changed in a merge request, with change type (ADD, MODIFY, DELETE, RENAME). " +
            "Use this before get_mr_diff to understand the scope of an MR before fetching the full patch.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                mrIid: { type: "number", description: "Merge request internal ID (iid)" },
            },
            required: ["project", "mrIid"],
        },
    },
    {
        name: "get_mr_diff",
        description:
            "Fetch the full unified diff of a merge request. " +
            "Shows exactly what lines were added and removed across all changed files. " +
            "Use get_mr_changes first to check scope — large MRs produce large diffs.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                mrIid: { type: "number", description: "Merge request internal ID (iid)" },
            },
            required: ["project", "mrIid"],
        },
    },
    {
        name: "get_file",
        description:
            "Fetch the contents of a file in a GitLab repository at a given branch, tag, or commit ref. " +
            "Use this to read source code for context when investigating a bug or understanding an implementation.",
        inputSchema: {
            type: "object",
            properties: {
                project: { type: "string", description: "GitLab project ID (numeric) or URL-encoded path with namespace (e.g. group/sub/repo)" },
                filePath: {
                    type: "string",
                    description: "Path to the file within the repo (e.g. src/main/java/App.java)",
                },
                ref: {
                    type: "string",
                    description: "Branch, tag, or commit hash (default: default branch)",
                },
            },
            required: ["project", "filePath"],
        },
    },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    try {
        let result;
        switch (name) {
            case "list_projects":
                result = await listProjects(args);
                break;
            case "get_commits":
                result = await getCommits(args);
                break;
            case "get_merge_requests":
                result = await getMergeRequests(args);
                break;
            case "get_merge_request":
                result = await getMergeRequest(args);
                break;
            case "get_mr_changes":
                result = await getMrChanges(args);
                break;
            case "get_mr_diff":
                result = await getMrDiff(args);
                break;
            case "get_file":
                result = await getFile(args);
                break;
            default:
                throw new Error(`Unknown tool: ${name}`);
        }

        return {
            content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
    } catch (err) {
        return toolError(err);
    }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("GitLab MCP server running");
