#!/usr/bin/env node
/**
 * Bitbucket MCP Server
 *
 * Provides read-only access to an internal Bitbucket Server instance.
 * Designed to run inside a Docker container that routes all traffic
 * through a Squid proxy — uses undici with ProxyAgent for all HTTP calls.
 *
 * Tools:
 *   list_projects       — list all accessible Bitbucket projects
 *   list_repos          — list all repos in a project
 *   get_commits         — recent commits for a repo (optionally filtered)
 *   get_pull_requests   — list open/merged PRs for a repo
 *   get_pull_request    — single PR with review comments
 *   get_pr_changes      — list files changed in a PR
 *   get_pr_diff         — full unified diff of a PR
 *   get_file            — file contents at a given ref
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { fetch } from "undici";
import { z } from "zod";
import { makeDispatcher, requireEnv, bearerAuth, toolError } from "../_lib/common.js";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

// Read the canonical .env names directly. docker compose passes these through
// env_file, so they're in the container environment and inherited by whatever
// process opencode spawns this server from (backend OR the TUI's docker exec) —
// unlike a var only export-ed at runtime by PID 1. The REST API authenticates
// with the PAT as a Bearer token (Bitbucket Data Center HTTP access tokens),
// so no username is needed here — BITBUCKET_USER is optional and consumed only
// by the git credential helper (git-over-HTTP still speaks Basic), which lives
// in the entrypoint, not this server.
requireEnv(["BITBUCKET_BASE_URL", "BITBUCKET_PAT"]);
// Bitbucket alone treats a missing proxy as fatal (preserving prior
// behavior); the other four servers fall back to a direct connection when no
// proxy is configured (see makeDispatcher()).
if (!process.env.HTTPS_PROXY && !process.env.HTTP_PROXY) {
    console.error("Missing required env vars: HTTPS_PROXY or HTTP_PROXY");
    process.exit(1);
}

const BB_BASE_URL = process.env.BITBUCKET_BASE_URL.replace(/\/$/, "");
const BB_PAT = process.env.BITBUCKET_PAT;

const BB_AUTH_HEADER = bearerAuth(BB_PAT);

const proxyAgent = makeDispatcher();

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

/**
 * Fetch a Bitbucket REST API endpoint and return parsed JSON.
 * Throws a descriptive error on non-2xx responses.
 */
async function bbFetch(path, params = {}) {
    const url = new URL(`${BB_BASE_URL}/rest/api/1.0${path}`);

    for (const [k, v] of Object.entries(params)) {
        if (v !== undefined && v !== null && v !== "") {
            url.searchParams.set(k, String(v));
        }
    }

    const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
            Authorization: BB_AUTH_HEADER,
            Accept: "application/json",
        },
        dispatcher: proxyAgent,
    });

    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(
            `Bitbucket API error ${response.status} for ${url.pathname}: ${body}`
        );
    }

    return response.json();
}

/**
 * Paginate through all pages of a Bitbucket list endpoint.
 * Bitbucket uses { values, isLastPage, nextPageStart } pagination.
 */
async function bbFetchAll(path, params = {}, maxItems = 200) {
    const items = [];
    let start = 0;
    let isLastPage = false;

    while (!isLastPage && items.length < maxItems) {
        const data = await bbFetch(path, { ...params, start, limit: 25 });
        items.push(...(data.values ?? []));
        isLastPage = data.isLastPage ?? true;
        start = data.nextPageStart ?? 0;
    }

    return items;
}

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

const ListProjectsSchema = z.object({
    limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .default(50)
        .describe("Max projects to return (default 50)"),
});

const ListReposSchema = z.object({
    projectKey: z.string().describe("Bitbucket project key (e.g. PROJ)"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(100)
        .default(50)
        .describe("Max repos to return (default 50)"),
});

const RepoArgs = {
    projectKey: z.string().describe("Bitbucket project key (e.g. PROJ)"),
    repoSlug: z.string().describe("Repository slug (e.g. my-service)"),
};

const GetCommitsSchema = z.object({
    ...RepoArgs,
    branch: z
        .string()
        .optional()
        .describe("Branch or ref to list commits from (default: default branch)"),
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

const GetPullRequestsSchema = z.object({
    ...RepoArgs,
    state: z
        .enum(["OPEN", "MERGED", "DECLINED", "ALL"])
        .default("OPEN")
        .describe("PR state filter (default OPEN)"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(50)
        .default(20)
        .describe("Max PRs to return (default 20)"),
});

const GetPullRequestSchema = z.object({
    ...RepoArgs,
    prId: z.number().int().describe("Pull request ID"),
});

const GetPrChangesSchema = z.object({
    ...RepoArgs,
    prId: z.number().int().describe("Pull request ID"),
});

const GetPrDiffSchema = z.object({
    ...RepoArgs,
    prId: z.number().int().describe("Pull request ID"),
    contextLines: z
        .number()
        .int()
        .min(0)
        .max(20)
        .default(5)
        .describe("Lines of context around each change (default 5)"),
});

const GetFileSchema = z.object({
    ...RepoArgs,
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
    const { limit } = ListProjectsSchema.parse(args ?? {});

    const projects = await bbFetchAll(`/projects`, {}, limit);

    return {
        count: projects.length,
        projects: projects.slice(0, limit).map((p) => ({
            key: p.key,
            name: p.name,
            description: p.description ?? null,
            type: p.type,
        })),
    };
}

async function listRepos(args) {
    const { projectKey, limit } = ListReposSchema.parse(args);

    const repos = await bbFetchAll(`/projects/${projectKey}/repos`, {}, limit);

    return {
        project: projectKey,
        count: repos.length,
        repos: repos.slice(0, limit).map((r) => ({
            slug: r.slug,
            name: r.name,
            description: r.description ?? null,
            state: r.state,
            defaultBranch: r.defaultBranch ?? null,
        })),
    };
}

async function getCommits(args) {
    const { projectKey, repoSlug, branch, query, limit } = GetCommitsSchema.parse(args);

    const params = {};
    if (branch) params.until = branch;
    // Bitbucket Server doesn't have a native message search param, so we
    // fetch more and filter client-side when a query is provided.
    const fetchLimit = query ? Math.min(limit * 5, 200) : limit;

    const commits = await bbFetchAll(
        `/projects/${projectKey}/repos/${repoSlug}/commits`,
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
                ? queryRe.test(c.message ?? "")
                : c.message?.toLowerCase().includes(query.toLowerCase())
        )
        : commits;

    const results = filtered.slice(0, limit).map((c) => ({
        id: c.id,
        displayId: c.displayId,
        message: c.message,
        author: c.author?.name ?? c.author?.emailAddress ?? "unknown",
        authorTimestamp: c.authorTimestamp
            ? new Date(c.authorTimestamp).toISOString()
            : null,
        parents: (c.parents ?? []).map((p) => p.displayId),
    }));

    return {
        project: projectKey,
        repo: repoSlug,
        branch: branch ?? "(default)",
        query: query ?? null,
        count: results.length,
        commits: results,
    };
}

async function getPullRequests(args) {
    const { projectKey, repoSlug, state, limit } = GetPullRequestsSchema.parse(args);

    const prs = await bbFetchAll(
        `/projects/${projectKey}/repos/${repoSlug}/pull-requests`,
        { state },
        limit
    );

    const results = prs.slice(0, limit).map((pr) => ({
        id: pr.id,
        title: pr.title,
        state: pr.state,
        description: pr.description ?? null,
        author: pr.author?.user?.displayName ?? pr.author?.user?.name ?? "unknown",
        createdDate: pr.createdDate ? new Date(pr.createdDate).toISOString() : null,
        updatedDate: pr.updatedDate ? new Date(pr.updatedDate).toISOString() : null,
        fromBranch: pr.fromRef?.displayId ?? null,
        toBranch: pr.toRef?.displayId ?? null,
        reviewers: (pr.reviewers ?? []).map((r) => ({
            name: r.user?.displayName ?? r.user?.name,
            status: r.status,
        })),
        links: pr.links?.self?.[0]?.href ?? null,
    }));

    return {
        project: projectKey,
        repo: repoSlug,
        state,
        count: results.length,
        pullRequests: results,
    };
}

async function getPullRequest(args) {
    const { projectKey, repoSlug, prId } = GetPullRequestSchema.parse(args);

    const basePath = `/projects/${projectKey}/repos/${repoSlug}/pull-requests/${prId}`;

    const [pr, activities] = await Promise.all([
        bbFetch(basePath),
        bbFetchAll(`${basePath}/activities`, {}, 100),
    ]);

    // Extract review comments from activities
    const comments = activities
        .filter((a) => a.action === "COMMENTED")
        .map((a) => ({
            author: a.user?.displayName ?? a.user?.name ?? "unknown",
            text: a.comment?.text ?? "",
            createdDate: a.createdDate
                ? new Date(a.createdDate).toISOString()
                : null,
            severity: a.comment?.severity ?? null,
        }));

    return {
        id: pr.id,
        title: pr.title,
        state: pr.state,
        description: pr.description ?? null,
        author: pr.author?.user?.displayName ?? pr.author?.user?.name ?? "unknown",
        createdDate: pr.createdDate ? new Date(pr.createdDate).toISOString() : null,
        updatedDate: pr.updatedDate ? new Date(pr.updatedDate).toISOString() : null,
        fromBranch: pr.fromRef?.displayId ?? null,
        fromCommit: pr.fromRef?.latestCommit ?? null,
        toBranch: pr.toRef?.displayId ?? null,
        toCommit: pr.toRef?.latestCommit ?? null,
        reviewers: (pr.reviewers ?? []).map((r) => ({
            name: r.user?.displayName ?? r.user?.name,
            status: r.status,
        })),
        reviewComments: comments,
        link: pr.links?.self?.[0]?.href ?? null,
    };
}

async function getPrChanges(args) {
    const { projectKey, repoSlug, prId } = GetPrChangesSchema.parse(args);

    const basePath = `/projects/${projectKey}/repos/${repoSlug}/pull-requests/${prId}`;
    const changes = await bbFetchAll(`${basePath}/changes`, {}, 500);

    const files = changes.map((c) => ({
        path: c.path?.toString ?? c.path,
        srcPath: c.srcPath?.toString ?? c.srcPath ?? null,
        type: c.type, // ADD, MODIFY, DELETE, RENAME, COPY
    }));

    return {
        project: projectKey,
        repo: repoSlug,
        prId,
        count: files.length,
        files,
    };
}

async function getPrDiff(args) {
    const { projectKey, repoSlug, prId, contextLines } = GetPrDiffSchema.parse(args);

    // The diff endpoint returns plain text, not JSON
    const url = new URL(
        `${BB_BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/pull-requests/${prId}/diff`
    );
    url.searchParams.set("contextLines", String(contextLines));
    url.searchParams.set("whitespace", "IGNORE_ALL");

    const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
            Authorization: BB_AUTH_HEADER,
            Accept: "application/json",
        },
        dispatcher: proxyAgent,
    });

    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(`Bitbucket API error ${response.status} for PR diff: ${body}`);
    }

    // Bitbucket returns structured diff JSON for this endpoint
    const data = await response.json();

    // Flatten into a readable unified-diff-style string per file
    const sections = (data.diffs ?? []).map((fileDiff) => {
        const fromPath = fileDiff.source?.toString ?? fileDiff.source ?? "/dev/null";
        const toPath = fileDiff.destination?.toString ?? fileDiff.destination ?? "/dev/null";
        const header = `--- ${fromPath}\n+++ ${toPath}`;

        const hunks = (fileDiff.hunks ?? []).map((hunk) => {
            const hunkHeader = `@@ -${hunk.sourceLine},${hunk.sourceSpan} +${hunk.destinationLine},${hunk.destinationSpan} @@`;
            const lines = (hunk.segments ?? []).flatMap((seg) => {
                const prefix =
                    seg.type === "ADDED" ? "+" : seg.type === "REMOVED" ? "-" : " ";
                return (seg.lines ?? []).map((l) => `${prefix}${l.line}`);
            });
            return [hunkHeader, ...lines].join("\n");
        });

        return [header, ...hunks].join("\n");
    });

    return {
        project: projectKey,
        repo: repoSlug,
        prId,
        contextLines,
        diff: sections.join("\n\n"),
    };
}

async function getFile(args) {
    const { projectKey, repoSlug, filePath, ref } = GetFileSchema.parse(args);

    // Bitbucket browse API returns paginated lines
    const params = {};
    if (ref) params.at = ref;
    params.limit = 500; // lines per page

    // Fetch first page to get line count
    const firstPage = await bbFetch(
        `/projects/${projectKey}/repos/${repoSlug}/browse/${filePath}`,
        params
    );

    // If it's a binary file, Bitbucket returns { binary: true }
    if (firstPage.binary) {
        return {
            project: projectKey,
            repo: repoSlug,
            path: filePath,
            ref: ref ?? "(default)",
            binary: true,
            content: null,
        };
    }

    // lines are in firstPage.lines[].text
    const lines = [...(firstPage.lines ?? [])];

    // Paginate if needed
    let page = firstPage;
    while (!page.isLastPage) {
        page = await bbFetch(
            `/projects/${projectKey}/repos/${repoSlug}/browse/${filePath}`,
            { ...params, start: page.nextPageStart }
        );
        lines.push(...(page.lines ?? []));
    }

    const content = lines.map((l) => l.text).join("\n");

    return {
        project: projectKey,
        repo: repoSlug,
        path: filePath,
        ref: ref ?? "(default)",
        binary: false,
        lines: lines.length,
        content,
    };
}

// ---------------------------------------------------------------------------
// MCP server setup
// ---------------------------------------------------------------------------
//
// Normalized onto McpServer + server.tool(...), same as the other four
// servers (this one used to be the odd one out on the older low-level
// Server/ListToolsRequestSchema/CallToolRequestSchema API). Every tool's
// name, description, effective input schema, and output text format
// (JSON.stringify(result, null, 2) on success) are unchanged — asTool()
// just wraps each <fn> the same way the old central CallToolRequestSchema
// handler's switch/try/catch did.

const server = new McpServer({ name: "bitbucket", version: "1.0.0" });

/** Wrap a tool implementation (args -> result) as an McpServer tool callback:
 * JSON.stringify the success value, and format thrown errors via the shared
 * toolError() helper (no stack — see _lib/common.js) — matching the old
 * central switch/try/catch exactly. */
function asTool(fn) {
    return async (args) => {
        try {
            const result = await fn(args);
            return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
        } catch (err) {
            return toolError(err);
        }
    };
}

server.tool(
    "list_projects",
    "List all Bitbucket projects accessible to the current user. " +
        "Use this first when you don't know the project key — it returns keys and display names for all projects.",
    ListProjectsSchema.shape,
    asTool(listProjects)
);

server.tool(
    "list_repos",
    "List all repositories in a Bitbucket project. " +
        "Use this to find the correct repo slug before calling get_commits, get_pull_requests, or get_file.",
    ListReposSchema.shape,
    asTool(listRepos)
);

server.tool(
    "get_commits",
    "Fetch recent commits for a Bitbucket repository. " +
        "Optionally filter by branch and/or a search string in the commit message (e.g. a Jira ticket key). " +
        "Useful for finding when a change was made or which commit introduced an issue.",
    GetCommitsSchema.shape,
    asTool(getCommits)
);

server.tool(
    "get_pull_requests",
    "List pull requests for a Bitbucket repository. " +
        "Returns title, author, status, reviewers, and description. " +
        "Use state=MERGED to find which PR delivered a feature.",
    GetPullRequestsSchema.shape,
    asTool(getPullRequests)
);

server.tool(
    "get_pull_request",
    "Fetch a single pull request by ID, including review comments. " +
        "Use this after get_pull_requests to deep-dive into a specific PR.",
    GetPullRequestSchema.shape,
    asTool(getPullRequest)
);

server.tool(
    "get_pr_changes",
    "List all files changed in a pull request, with change type (ADD, MODIFY, DELETE, RENAME). " +
        "Use this before get_pr_diff to understand the scope of a PR before fetching the full patch.",
    GetPrChangesSchema.shape,
    asTool(getPrChanges)
);

server.tool(
    "get_pr_diff",
    "Fetch the full unified diff of a pull request. " +
        "Shows exactly what lines were added and removed across all changed files. " +
        "Use get_pr_changes first to check scope — large PRs produce large diffs.",
    GetPrDiffSchema.shape,
    asTool(getPrDiff)
);

server.tool(
    "get_file",
    "Fetch the contents of a file in a Bitbucket repository at a given branch, tag, or commit ref. " +
        "Use this to read source code for context when investigating a bug or understanding an implementation.",
    GetFileSchema.shape,
    asTool(getFile)
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("Bitbucket MCP server running");