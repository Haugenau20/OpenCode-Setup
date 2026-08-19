#!/usr/bin/env node
/**
 * GitLab MCP Server
 *
 * Read access to an internal GitLab instance, plus an OPT-IN write surface.
 * Designed to run inside a Docker container that routes all traffic
 * through a Squid proxy — uses undici with ProxyAgent for all HTTP calls.
 *
 * Read tools (always available):
 *   list_projects          — discover/search accessible GitLab projects
 *   get_commits            — recent commits for a project (optionally filtered)
 *   get_merge_requests     — list open/merged/closed MRs for a project
 *   get_merge_request      — single MR with notes/comments
 *   get_mr_changes         — list files changed in an MR
 *   get_mr_diff            — full unified diff of an MR
 *   get_file               — file contents at a given ref
 *   list_issues            — issues filtered by label/state/search
 *   get_issue              — single issue with labels and description
 *   get_issue_notes        — comments on an issue
 *   get_pipelines          — CI pipelines for a ref (is the branch green?)
 *
 * Write tools (ONLY when ALLOW_GITLAB_WRITE=1 — see below):
 *   create_issue           — file a follow-up (reserved labels refused)
 *   create_issue_note      — comment on an issue
 *   update_issue_note      — edit a comment in place (the workpad pattern)
 *   create_merge_request   — open an MR
 *   update_merge_request   — retitle / rewrite an MR description
 *   create_mr_note         — reply on a merge request
 *
 * The write surface exists so the agent can publish its work — open an MR,
 * answer review comments — without a human relaying it by hand. It is OFF by
 * default and gated twice: the tools are not listed unless the switch is on,
 * AND every write handler re-checks before acting, because a client can call a
 * tool it was never offered.
 *
 * What is deliberately NOT here, even with the switch on: anything that sets
 * issue labels or open/closed state, merges an MR, or deletes anything. Where
 * an external orchestrator drives work through issue labels, the label IS the
 * state and that orchestrator owns it; an agent able to relabel its own issue
 * could mark its own work reviewed or feed itself new work forever. Merging is
 * a human decision. See docs/ARCHITECTURE.md, "The credential model".
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
import { writeEnabled, assertWriteAllowed, assertNoReservedLabels } from "../_lib/write_gate.js";

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

// Write gate. OFF unless ALLOW_GITLAB_WRITE=1, optionally narrowed further by
// GITLAB_WRITE_PROJECTS (whitespace/comma-separated project paths or ids,
// prefix-matched on a path-segment boundary — same rule as
// GIT_REMOTE_ALLOWLIST). Read once at startup for the tool listing; every write
// handler re-checks per call, since listing is not enforcement.
const WRITES_ENABLED = writeEnabled("GITLAB");

// Label namespace the agent may never set — reserved for whatever drives work
// through issue labels. The default matches the `symphony::` prefix used by the
// external orchestrator this gate was first written for; an orchestrator that
// names its states differently sets GITLAB_QUEUE_LABEL_PREFIX to match. Changing
// the default would silently stop the gate matching for anyone relying on it.
const QUEUE_LABEL_PREFIX = process.env.GITLAB_QUEUE_LABEL_PREFIX || "symphony";

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
 * Send a mutating request (POST/PUT) with a JSON body and return parsed JSON.
 * Separate from glFetch so that helper stays unambiguously a GET — a single
 * function taking a method is one typo away from a write.
 */
async function glWrite(method, path, body) {
    const url = new URL(`${GITLAB_BASE_URL}/api/v4${path}`);

    const response = await fetch(url.toString(), {
        method,
        headers: {
            "PRIVATE-TOKEN": privateTokenAuth(GITLAB_PAT),
            Accept: "application/json",
            "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        dispatcher: proxyAgent,
    });

    if (!response.ok) {
        const text = await response.text().catch(() => "");
        // 403 here is usually the token's ROLE, not its scope: a Reporter can
        // comment but cannot open a merge request. Say so, because the model
        // will otherwise retry the same call.
        const hint = response.status === 403
            ? " (403 — check the token's role: Reporter can comment on issues but cannot create merge requests)"
            : "";
        throw new Error(
            `GitLab API error ${response.status} for ${url.pathname}${hint}: ${text}`
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


// --- issues / notes / pipelines ---

const ListIssuesSchema = z.object({
    ...ProjectArg,
    labels: z.union([z.string(), z.array(z.string())]).optional()
        .describe("Label filter. GitLab ANDs these — every label must be present"),
    state: z.enum(["opened", "closed", "all"]).optional().describe("Issue state (default all)"),
    search: z.string().optional().describe("Search term over title and description"),
    limit: z.number().int().min(1).max(100).default(50).describe("Max issues (default 50)"),
});

const GetIssueSchema = z.object({
    ...ProjectArg,
    issueIid: z.number().int().describe("Issue iid (the #N shown in the UI), not the global id"),
});

const GetIssueNotesSchema = z.object({
    ...ProjectArg,
    issueIid: z.number().int().describe("Issue iid"),
    limit: z.number().int().min(1).max(100).default(50).describe("Max notes (default 50)"),
});

const GetPipelinesSchema = z.object({
    ...ProjectArg,
    ref: z.string().optional().describe("Branch or tag to filter by"),
    sha: z.string().optional().describe("Commit SHA to filter by"),
    limit: z.number().int().min(1).max(50).default(10).describe("Max pipelines (default 10)"),
});

// --- writes (only reachable when ALLOW_GITLAB_WRITE=1) ---

const CreateIssueSchema = z.object({
    ...ProjectArg,
    title: z.string().min(1).describe("Issue title"),
    description: z.string().optional().describe("Markdown body"),
    labels: z.array(z.string()).optional()
        .describe("Labels. The workflow-state namespace is refused — a follow-up cannot enqueue itself"),
});

const CreateIssueNoteSchema = z.object({
    ...ProjectArg,
    issueIid: z.number().int().describe("Issue iid"),
    body: z.string().min(1).describe("Markdown comment body"),
});

const UpdateIssueNoteSchema = z.object({
    ...ProjectArg,
    issueIid: z.number().int().describe("Issue iid"),
    noteId: z.number().int().describe("Note id from get_issue_notes"),
    body: z.string().min(1).describe("Replacement body — this replaces the note entirely"),
});

const CreateMergeRequestSchema = z.object({
    ...ProjectArg,
    sourceBranch: z.string().min(1).describe("Branch holding the work"),
    targetBranch: z.string().min(1).describe("Branch to merge into (usually the default branch)"),
    title: z.string().min(1).describe("MR title"),
    description: z.string().optional()
        .describe("Markdown body. Include `Closes #N` so GitLab links the MR to its issue"),
    removeSourceBranch: z.boolean().default(true).describe("Delete the source branch on merge"),
});

const UpdateMergeRequestSchema = z.object({
    ...ProjectArg,
    mrIid: z.number().int().describe("Merge request iid"),
    title: z.string().optional().describe("New title"),
    description: z.string().optional().describe("New description — replaces the existing one"),
});

const CreateMrNoteSchema = z.object({
    ...ProjectArg,
    mrIid: z.number().int().describe("Merge request iid"),
    body: z.string().min(1).describe("Markdown comment body"),
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
// Issues, notes, pipelines (read)
// ---------------------------------------------------------------------------

/** Trim a GitLab issue to the fields worth spending context on. */
function slimIssue(issue) {
    return {
        iid: issue.iid,
        title: issue.title,
        state: issue.state,
        labels: issue.labels ?? [],
        description: issue.description ?? null,
        author: issue.author?.username ?? null,
        assignees: (issue.assignees ?? []).map((a) => a.username),
        milestone: issue.milestone?.title ?? null,
        web_url: issue.web_url,
        created_at: issue.created_at,
        updated_at: issue.updated_at,
    };
}

async function listIssues(args) {
    const { project, labels, state, search, limit = 50 } = ListIssuesSchema.parse(args);
    const issues = await glFetchAll(
        `/projects/${encodeProjectId(project)}/issues`,
        {
            // GitLab ANDs the labels parameter — every label listed must be
            // present. There is no OR, so filter client-side if you need one.
            labels: Array.isArray(labels) ? labels.join(",") : labels,
            state,
            search,
            order_by: "updated_at",
        },
        limit
    );
    return { project, count: issues.length, issues: issues.slice(0, limit).map(slimIssue) };
}

async function getIssue(args) {
    const { project, issueIid } = GetIssueSchema.parse(args);
    const issue = await glFetch(`/projects/${encodeProjectId(project)}/issues/${issueIid}`);
    return slimIssue(issue);
}

async function getIssueNotes(args) {
    const { project, issueIid, limit = 50 } = GetIssueNotesSchema.parse(args);
    const notes = await glFetchAll(
        `/projects/${encodeProjectId(project)}/issues/${issueIid}/notes`,
        { sort: "asc", order_by: "created_at" },
        limit
    );
    return {
        project,
        issueIid,
        count: notes.length,
        // `id` matters: update_issue_note needs it to edit a comment in place.
        notes: notes.filter((n) => !n.system).map((n) => ({
            id: n.id,
            author: n.author?.username ?? null,
            body: n.body,
            created_at: n.created_at,
            updated_at: n.updated_at,
        })),
    };
}

async function getPipelines(args) {
    const { project, ref, sha, limit = 10 } = GetPipelinesSchema.parse(args);
    const pipelines = await glFetchAll(
        `/projects/${encodeProjectId(project)}/pipelines`,
        { ref, sha, order_by: "id", sort: "desc" },
        limit
    );
    return {
        project,
        ref: ref ?? null,
        count: pipelines.length,
        pipelines: pipelines.slice(0, limit).map((p) => ({
            id: p.id,
            status: p.status,
            ref: p.ref,
            sha: p.sha,
            web_url: p.web_url,
            created_at: p.created_at,
            updated_at: p.updated_at,
        })),
    };
}

// ---------------------------------------------------------------------------
// Writes — every one of these re-checks the gate before acting
// ---------------------------------------------------------------------------

async function createIssue(args) {
    const { project, title, description, labels } = CreateIssueSchema.parse(args);
    assertWriteAllowed("GITLAB", project);
    // A follow-up issue must not be able to admit itself to the work queue.
    assertNoReservedLabels(labels, QUEUE_LABEL_PREFIX);

    const issue = await glWrite("POST", `/projects/${encodeProjectId(project)}/issues`, {
        title,
        description: description ?? "",
        labels: (labels ?? []).join(","),
    });
    return slimIssue(issue);
}

async function createIssueNote(args) {
    const { project, issueIid, body } = CreateIssueNoteSchema.parse(args);
    assertWriteAllowed("GITLAB", project);
    const note = await glWrite(
        "POST",
        `/projects/${encodeProjectId(project)}/issues/${issueIid}/notes`,
        { body }
    );
    return { id: note.id, issueIid, created_at: note.created_at };
}

async function updateIssueNote(args) {
    const { project, issueIid, noteId, body } = UpdateIssueNoteSchema.parse(args);
    assertWriteAllowed("GITLAB", project);
    const note = await glWrite(
        "PUT",
        `/projects/${encodeProjectId(project)}/issues/${issueIid}/notes/${noteId}`,
        { body }
    );
    return { id: note.id, issueIid, updated_at: note.updated_at };
}

async function createMergeRequest(args) {
    const {
        project, sourceBranch, targetBranch, title, description, removeSourceBranch = true,
    } = CreateMergeRequestSchema.parse(args);
    assertWriteAllowed("GITLAB", project);

    const mr = await glWrite("POST", `/projects/${encodeProjectId(project)}/merge_requests`, {
        source_branch: sourceBranch,
        target_branch: targetBranch,
        title,
        description: description ?? "",
        remove_source_branch: removeSourceBranch,
    });
    return {
        iid: mr.iid, title: mr.title, state: mr.state,
        source_branch: mr.source_branch, target_branch: mr.target_branch,
        web_url: mr.web_url, created_at: mr.created_at,
    };
}

async function updateMergeRequest(args) {
    const { project, mrIid, title, description } = UpdateMergeRequestSchema.parse(args);
    assertWriteAllowed("GITLAB", project);
    if (title === undefined && description === undefined) {
        throw new Error("Nothing to update: pass title, description, or both.");
    }
    const body = {};
    if (title !== undefined) body.title = title;
    if (description !== undefined) body.description = description;

    const mr = await glWrite(
        "PUT", `/projects/${encodeProjectId(project)}/merge_requests/${mrIid}`, body
    );
    return { iid: mr.iid, title: mr.title, state: mr.state, web_url: mr.web_url };
}

async function createMrNote(args) {
    const { project, mrIid, body } = CreateMrNoteSchema.parse(args);
    assertWriteAllowed("GITLAB", project);
    const note = await glWrite(
        "POST",
        `/projects/${encodeProjectId(project)}/merge_requests/${mrIid}/notes`,
        { body }
    );
    return { id: note.id, mrIid, created_at: note.created_at };
}

// ---------------------------------------------------------------------------
// MCP server setup
// ---------------------------------------------------------------------------

const server = new Server(
    { name: "gitlab", version: "1.0.0" },
    { capabilities: { tools: {} } }
);

const PROJECT_PROP = { type: "string", description: "GitLab project ID (numeric) or path with namespace (e.g. group/sub/repo)" };

const READ_TOOLS = [
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
    {
        name: "list_issues",
        description:
            "List issues in a project, optionally filtered by label, state or a search term. " +
            "Note GitLab ANDs the label filter — every label given must be present on the issue; " +
            "there is no OR, so fetch broadly and filter yourself if you need one.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                labels: { type: "array", items: { type: "string" }, description: "Labels that must ALL be present" },
                state: { type: "string", description: "opened | closed | all (default all)" },
                search: { type: "string", description: "Search term over title and description" },
                limit: { type: "number", description: "Max issues (default 50)" },
            },
            required: ["project"],
        },
    },
    {
        name: "get_issue",
        description:
            "Fetch a single issue by iid — the #N shown in the UI, scoped to the project, NOT the global id. " +
            "Returns title, state, labels, description, assignees and web_url. This is how you read your brief.",
        inputSchema: {
            type: "object",
            properties: { project: PROJECT_PROP, issueIid: { type: "number", description: "Issue iid (#N)" } },
            required: ["project", "issueIid"],
        },
    },
    {
        name: "get_issue_notes",
        description:
            "Read the comments on an issue, oldest first, with system notes filtered out. " +
            "Each note carries its `id`, which update_issue_note needs to edit a comment in place.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                issueIid: { type: "number", description: "Issue iid (#N)" },
                limit: { type: "number", description: "Max notes (default 50)" },
            },
            required: ["project", "issueIid"],
        },
    },
    {
        name: "get_pipelines",
        description:
            "Recent CI pipelines for a project, newest first, optionally filtered by branch or commit. " +
            "Use it to confirm a branch is green before asking a human to review it.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                ref: { type: "string", description: "Branch or tag" },
                sha: { type: "string", description: "Commit SHA" },
                limit: { type: "number", description: "Max pipelines (default 10)" },
            },
            required: ["project"],
        },
    },
];

// Offered only when ALLOW_GITLAB_WRITE=1. Hiding them is not the enforcement —
// the handlers re-check — but a capability the model is never shown is a
// capability it never wastes a turn trying to use.
const WRITE_TOOLS = [
    {
        name: "create_issue",
        description:
            "Create a new issue — for filing out-of-scope follow-up work you discovered, NOT for enqueuing work " +
            "for yourself. Workflow-state labels are refused: a new issue arrives unlabelled and a human decides " +
            "whether it enters the queue.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                title: { type: "string", description: "Issue title" },
                description: { type: "string", description: "Markdown body" },
                labels: { type: "array", items: { type: "string" }, description: "Labels (workflow-state namespace refused)" },
            },
            required: ["project", "title"],
        },
    },
    {
        name: "create_issue_note",
        description:
            "Post a comment on an issue. For a running progress log, post ONCE and then edit that note with " +
            "update_issue_note — a thread of twenty status comments is noise for whoever reviews this.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                issueIid: { type: "number", description: "Issue iid (#N)" },
                body: { type: "string", description: "Markdown comment body" },
            },
            required: ["project", "issueIid", "body"],
        },
    },
    {
        name: "update_issue_note",
        description:
            "Replace the body of an existing issue comment, found via get_issue_notes. This is how a progress " +
            "workpad stays one comment instead of a wall of them. The body is replaced entirely, not appended to.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                issueIid: { type: "number", description: "Issue iid (#N)" },
                noteId: { type: "number", description: "Note id from get_issue_notes" },
                body: { type: "string", description: "Replacement body (replaces the whole note)" },
            },
            required: ["project", "issueIid", "noteId", "body"],
        },
    },
    {
        name: "create_merge_request",
        description:
            "Open a merge request from a pushed branch. Put `Closes #N` in the description so GitLab links it to " +
            "the issue — that link is the review surface. Opening an MR is the end of your work; merging is a " +
            "human decision and your token cannot do it.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                sourceBranch: { type: "string", description: "Branch holding the work" },
                targetBranch: { type: "string", description: "Branch to merge into (usually the default branch)" },
                title: { type: "string", description: "MR title" },
                description: { type: "string", description: "Markdown body — include `Closes #N`" },
                removeSourceBranch: { type: "boolean", description: "Delete source branch on merge (default true)" },
            },
            required: ["project", "sourceBranch", "targetBranch", "title"],
        },
    },
    {
        name: "update_merge_request",
        description:
            "Change an existing merge request's title and/or description. The description is replaced entirely, " +
            "so read it first if you mean to amend rather than overwrite.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                mrIid: { type: "number", description: "Merge request iid" },
                title: { type: "string", description: "New title" },
                description: { type: "string", description: "New description (replaces the existing one)" },
            },
            required: ["project", "mrIid"],
        },
    },
    {
        name: "create_mr_note",
        description:
            "Comment on a merge request — use it to answer a reviewer, including to explain why you are NOT " +
            "making a requested change. A reviewer comment you disagree with still needs a reply.",
        inputSchema: {
            type: "object",
            properties: {
                project: PROJECT_PROP,
                mrIid: { type: "number", description: "Merge request iid" },
                body: { type: "string", description: "Markdown comment body" },
            },
            required: ["project", "mrIid", "body"],
        },
    },
];

const WRITE_TOOL_NAMES = new Set(WRITE_TOOLS.map((t) => t.name));

// What the model actually sees.
const TOOLS = WRITES_ENABLED ? [...READ_TOOLS, ...WRITE_TOOLS] : READ_TOOLS;

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    try {
        // Listing is not enforcement — a client can call a tool it was never
        // offered — so the switch is gated too.
        if (WRITE_TOOL_NAMES.has(name) && !WRITES_ENABLED) {
            throw new Error(
                `Tool "${name}" writes to GitLab and writes are disabled. ` +
                `Set ALLOW_GITLAB_WRITE=1 in .env and restart to enable them. ` +
                `Do not route around this by calling the API directly — the setting is deliberate.`
            );
        }

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
            case "list_issues":
                result = await listIssues(args);
                break;
            case "get_issue":
                result = await getIssue(args);
                break;
            case "get_issue_notes":
                result = await getIssueNotes(args);
                break;
            case "get_pipelines":
                result = await getPipelines(args);
                break;
            case "create_issue":
                result = await createIssue(args);
                break;
            case "create_issue_note":
                result = await createIssueNote(args);
                break;
            case "update_issue_note":
                result = await updateIssueNote(args);
                break;
            case "create_merge_request":
                result = await createMergeRequest(args);
                break;
            case "update_merge_request":
                result = await updateMergeRequest(args);
                break;
            case "create_mr_note":
                result = await createMrNote(args);
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
console.error(
    `GitLab MCP server running (writes ${WRITES_ENABLED ? "ENABLED" : "disabled"}${
        WRITES_ENABLED && process.env.GITLAB_WRITE_PROJECTS
            ? `, projects: ${process.env.GITLAB_WRITE_PROJECTS}`
            : ""
    })`
);
