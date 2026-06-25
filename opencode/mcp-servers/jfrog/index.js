#!/usr/bin/env node
/**
 * JFrog Artifactory MCP Server
 *
 * Provides read-only access to an internal JFrog Artifactory instance.
 * Designed to run inside a Docker container that routes all traffic
 * through a Squid proxy — uses undici with ProxyAgent for all HTTP calls.
 *
 * JFrog is an artifact repository, NOT a git remote, so (unlike Bitbucket
 * and GitLab) it has no git transport — the API plane is all there is, much
 * like Jira. It authenticates the access token as a Bearer token (verified),
 * so no username is involved.
 *
 * Tools:
 *   list_repositories  — discover repositories (filter by type/packageType)
 *   get_repository      — configuration of a single repository
 *   search_artifacts    — quick search for artifacts by name
 *   gavc_search         — Maven GAVC coordinate search (group/artifact/version/classifier)
 *   latest_version      — resolve the latest version of a Maven artifact
 *   get_item_info       — storage metadata for a file or folder (children, size, checksums)
 *   get_file            — raw contents of a text artifact (poms, manifests, etc.)
 *   list_builds         — published CI build names (build-info)
 *   get_build           — build numbers/history for a build name
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
    CallToolRequestSchema,
    ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { fetch, ProxyAgent } from "undici";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

// Read the canonical .env names directly. docker compose passes these through
// env_file, so they're in the container environment and inherited by whatever
// process opencode spawns this server from (backend OR the TUI's docker exec) —
// unlike a var only export-ed at runtime by PID 1. JFrog has no git transport,
// so there is no JFROG_USER: the access token is presented as a Bearer token,
// the same shape as Jira.
const JFROG_BASE_URL = process.env.JFROG_BASE_URL?.replace(/\/$/, "");
const JFROG_PAT = process.env.JFROG_PAT;
const PROXY_URL = process.env.HTTPS_PROXY || process.env.HTTP_PROXY;

if (!JFROG_BASE_URL) throw new Error("JFROG_BASE_URL is not set");
if (!JFROG_PAT) throw new Error("JFROG_PAT is not set");

// TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in policy.yaml).
// Do NOT re-add rejectUnauthorized:false — a locked-down image must not skip
// certificate verification. If TLS to JFrog fails here, the CA isn't in the
// baked bundle; fix the CA, don't disable the check.
const proxyAgent = PROXY_URL ? new ProxyAgent(PROXY_URL) : undefined;

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

function jfHeaders(accept = "application/json") {
    return {
        Authorization: `Bearer ${JFROG_PAT}`,
        Accept: accept,
    };
}

/**
 * Fetch a JFrog Artifactory REST API endpoint and return parsed JSON.
 * `path` is relative to the Artifactory API root (e.g. "/repositories").
 * Throws a descriptive error on non-2xx responses.
 */
async function jfFetch(path, params = {}) {
    const url = new URL(`${JFROG_BASE_URL}/artifactory/api${path}`);

    for (const [k, v] of Object.entries(params)) {
        if (v !== undefined && v !== null && v !== "") {
            url.searchParams.set(k, String(v));
        }
    }

    const response = await fetch(url.toString(), {
        method: "GET",
        headers: jfHeaders(),
        dispatcher: proxyAgent,
    });

    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(
            `JFrog API error ${response.status} for ${url.pathname}: ${body}`
        );
    }

    return response.json();
}

/**
 * Fetch a raw artifact (not the REST API) — used by get_file. The download
 * route is `${base}/artifactory/<repoKey>/<path>`, with no `/api` segment.
 * Returns the undici Response so the caller can inspect headers/body.
 */
async function jfDownload(repoKey, filePath) {
    const clean = filePath.replace(/^\/+/, "");
    const url = `${JFROG_BASE_URL}/artifactory/${encodeURI(repoKey)}/${encodeURI(clean)}`;
    return fetch(url, {
        method: "GET",
        headers: jfHeaders("*/*"),
        dispatcher: proxyAgent,
    });
}

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

const ListRepositoriesSchema = z.object({
    type: z
        .enum(["local", "remote", "virtual", "federated", "distribution"])
        .optional()
        .describe("Filter by repository type (default: all types)"),
    packageType: z
        .string()
        .optional()
        .describe("Filter by package type, e.g. maven, npm, docker, pypi, generic"),
});

const GetRepositorySchema = z.object({
    repoKey: z.string().describe("Repository key (e.g. libs-release-local)"),
});

const SearchArtifactsSchema = z.object({
    name: z.string().describe("Artifact name (or fragment) to search for"),
    repos: z
        .string()
        .optional()
        .describe("Comma-separated list of repositories to scope the search to"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(200)
        .default(50)
        .describe("Max results to return (default 50)"),
});

const GavcSearchSchema = z.object({
    g: z.string().optional().describe("Maven groupId"),
    a: z.string().optional().describe("Maven artifactId"),
    v: z.string().optional().describe("Maven version"),
    c: z.string().optional().describe("Maven classifier"),
    repos: z
        .string()
        .optional()
        .describe("Comma-separated list of repositories to scope the search to"),
    limit: z
        .number()
        .int()
        .min(1)
        .max(200)
        .default(50)
        .describe("Max results to return (default 50)"),
});

const LatestVersionSchema = z.object({
    g: z.string().describe("Maven groupId"),
    a: z.string().describe("Maven artifactId"),
    v: z
        .string()
        .optional()
        .describe("Version prefix with a trailing wildcard, e.g. 1.2.* (optional)"),
    repos: z
        .string()
        .optional()
        .describe("Comma-separated list of repositories to scope the search to"),
});

const GetItemInfoSchema = z.object({
    repoKey: z.string().describe("Repository key (e.g. libs-release-local)"),
    path: z
        .string()
        .default("")
        .describe("Path within the repository (default: repository root)"),
});

const GetFileSchema = z.object({
    repoKey: z.string().describe("Repository key (e.g. libs-release-local)"),
    path: z
        .string()
        .describe("Path to the artifact within the repository (e.g. com/acme/app/1.0/app-1.0.pom)"),
});

const GetBuildSchema = z.object({
    buildName: z.string().describe("Build name as published to Artifactory build-info"),
});

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

async function listRepositories(args) {
    const { type, packageType } = ListRepositoriesSchema.parse(args ?? {});

    const params = {};
    if (type) params.type = type;
    if (packageType) params.packageType = packageType;

    const repos = await jfFetch(`/repositories`, params);

    return {
        count: Array.isArray(repos) ? repos.length : 0,
        repositories: (Array.isArray(repos) ? repos : []).map((r) => ({
            key: r.key,
            type: r.type ?? null,
            packageType: r.packageType ?? null,
            url: r.url ?? null,
            description: r.description ?? null,
        })),
    };
}

async function getRepository(args) {
    const { repoKey } = GetRepositorySchema.parse(args);
    const config = await jfFetch(`/repositories/${encodeURIComponent(repoKey)}`);
    return config;
}

async function searchArtifacts(args) {
    const { name, repos, limit } = SearchArtifactsSchema.parse(args);

    const params = { name };
    if (repos) params.repos = repos;

    const data = await jfFetch(`/search/artifact`, params);
    const results = (data.results ?? []).slice(0, limit).map((r) => ({
        uri: r.uri ?? null,
    }));

    return { query: name, count: results.length, results };
}

async function gavcSearch(args) {
    const { g, a, v, c, repos, limit } = GavcSearchSchema.parse(args);

    if (!g && !a && !v && !c) {
        throw new Error("gavc_search needs at least one of g, a, v, or c");
    }

    const params = {};
    if (g) params.g = g;
    if (a) params.a = a;
    if (v) params.v = v;
    if (c) params.c = c;
    if (repos) params.repos = repos;

    const data = await jfFetch(`/search/gavc`, params);
    const results = (data.results ?? []).slice(0, limit).map((r) => ({
        uri: r.uri ?? null,
    }));

    return { count: results.length, results };
}

async function latestVersion(args) {
    const { g, a, v, repos } = LatestVersionSchema.parse(args);

    // The latestVersion endpoint returns the version as PLAIN TEXT, not JSON,
    // so we hit it directly rather than via jfFetch.
    const url = new URL(`${JFROG_BASE_URL}/artifactory/api/search/latestVersion`);
    url.searchParams.set("g", g);
    url.searchParams.set("a", a);
    if (v) url.searchParams.set("v", v);
    if (repos) url.searchParams.set("repos", repos);

    const response = await fetch(url.toString(), {
        method: "GET",
        headers: jfHeaders("text/plain"),
        dispatcher: proxyAgent,
    });

    if (response.status === 404) {
        return { groupId: g, artifactId: a, found: false, version: null };
    }
    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(`JFrog API error ${response.status} for latestVersion: ${body}`);
    }

    const version = (await response.text()).trim();
    return { groupId: g, artifactId: a, found: true, version };
}

async function getItemInfo(args) {
    const { repoKey, path } = GetItemInfoSchema.parse(args);

    const clean = path.replace(/^\/+/, "");
    const storagePath = clean
        ? `${encodeURIComponent(repoKey)}/${clean.split("/").map(encodeURIComponent).join("/")}`
        : encodeURIComponent(repoKey);

    let info;
    try {
        info = await jfFetch(`/storage/${storagePath}`);
    } catch (err) {
        if (/error 404/i.test(err.message)) {
            return { repoKey, path: clean, found: false };
        }
        throw err;
    }

    // Folders carry a `children` array; files carry size/checksums/mimeType.
    const isFolder = Array.isArray(info.children);
    return {
        repoKey,
        path: clean,
        found: true,
        type: isFolder ? "folder" : "file",
        created: info.created ?? null,
        lastModified: info.lastModified ?? null,
        size: info.size ?? null,
        mimeType: info.mimeType ?? null,
        checksums: info.checksums ?? null,
        children: isFolder
            ? info.children.map((ch) => ({ uri: ch.uri, folder: ch.folder }))
            : undefined,
        downloadUri: info.downloadUri ?? null,
    };
}

async function getFile(args) {
    const { repoKey, path } = GetFileSchema.parse(args);

    const response = await jfDownload(repoKey, path);

    if (response.status === 404) {
        return { repoKey, path, found: false, content: null };
    }
    if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(`JFrog download error ${response.status} for ${repoKey}/${path}: ${body}`);
    }

    const buf = Buffer.from(await response.arrayBuffer());
    // Heuristic: treat as binary if it contains a NUL byte (same rule as the
    // GitLab/Bitbucket get_file tools) — don't dump binary into the context.
    if (buf.includes(0)) {
        return { repoKey, path, found: true, binary: true, size: buf.length, content: null };
    }

    return {
        repoKey,
        path,
        found: true,
        binary: false,
        size: buf.length,
        content: buf.toString("utf8"),
    };
}

async function listBuilds() {
    let data;
    try {
        data = await jfFetch(`/build`);
    } catch (err) {
        // Artifactory returns 404 when build-info has never been published.
        if (/error 404/i.test(err.message)) {
            return { count: 0, builds: [] };
        }
        throw err;
    }

    const builds = (data.builds ?? []).map((b) => ({
        // The API returns the name in `uri` as "/<name>".
        name: (b.uri ?? "").replace(/^\//, ""),
        lastStarted: b.lastStarted ?? null,
    }));

    return { count: builds.length, builds };
}

async function getBuild(args) {
    const { buildName } = GetBuildSchema.parse(args);

    let data;
    try {
        data = await jfFetch(`/build/${encodeURIComponent(buildName)}`);
    } catch (err) {
        if (/error 404/i.test(err.message)) {
            return { buildName, found: false, builds: [] };
        }
        throw err;
    }

    const numbers = (data.buildsNumbers ?? []).map((b) => ({
        number: (b.uri ?? "").replace(/^\//, ""),
        started: b.started ?? null,
    }));

    return { buildName, found: true, count: numbers.length, builds: numbers };
}

// ---------------------------------------------------------------------------
// MCP server setup
// ---------------------------------------------------------------------------

const server = new Server(
    { name: "jfrog", version: "1.0.0" },
    { capabilities: { tools: {} } }
);

const TOOLS = [
    {
        name: "list_repositories",
        description:
            "Discover JFrog Artifactory repositories, optionally filtered by type " +
            "(local/remote/virtual/federated/distribution) or packageType (maven, npm, docker, pypi, generic, ...). " +
            "Call this first when you don't know a repository key — it returns key, type, packageType, url, and description.",
        inputSchema: {
            type: "object",
            properties: {
                type: {
                    type: "string",
                    enum: ["local", "remote", "virtual", "federated", "distribution"],
                    description: "Filter by repository type (default: all)",
                },
                packageType: {
                    type: "string",
                    description: "Filter by package type, e.g. maven, npm, docker, pypi, generic",
                },
            },
            required: [],
        },
    },
    {
        name: "get_repository",
        description:
            "Fetch the configuration of a single repository by key — type, packageType, layout, " +
            "and (for remote/virtual repos) the upstream URL or aggregated members.",
        inputSchema: {
            type: "object",
            properties: {
                repoKey: { type: "string", description: "Repository key (e.g. libs-release-local)" },
            },
            required: ["repoKey"],
        },
    },
    {
        name: "search_artifacts",
        description:
            "Quick search for artifacts by file name (or fragment) across Artifactory, optionally scoped " +
            "to specific repositories. Returns the API URIs of matching artifacts. Use this when you know " +
            "(part of) a file name but not where it lives.",
        inputSchema: {
            type: "object",
            properties: {
                name: { type: "string", description: "Artifact name or fragment to search for" },
                repos: { type: "string", description: "Comma-separated repositories to scope the search to" },
                limit: { type: "number", description: "Max results to return (default 50, max 200)" },
            },
            required: ["name"],
        },
    },
    {
        name: "gavc_search",
        description:
            "Search Maven artifacts by GAVC coordinates (groupId / artifactId / version / classifier). " +
            "Supply at least one coordinate. Use this to find all versions of a Maven module or locate a " +
            "specific artifact across repositories.",
        inputSchema: {
            type: "object",
            properties: {
                g: { type: "string", description: "Maven groupId" },
                a: { type: "string", description: "Maven artifactId" },
                v: { type: "string", description: "Maven version" },
                c: { type: "string", description: "Maven classifier" },
                repos: { type: "string", description: "Comma-separated repositories to scope the search to" },
                limit: { type: "number", description: "Max results to return (default 50, max 200)" },
            },
            required: [],
        },
    },
    {
        name: "latest_version",
        description:
            "Resolve the latest version of a Maven artifact by groupId + artifactId. " +
            "Optionally pass a version prefix with a trailing wildcard (e.g. 1.2.*) to scope to a release line. " +
            "Returns the single latest version string.",
        inputSchema: {
            type: "object",
            properties: {
                g: { type: "string", description: "Maven groupId" },
                a: { type: "string", description: "Maven artifactId" },
                v: { type: "string", description: "Version prefix with trailing wildcard, e.g. 1.2.* (optional)" },
                repos: { type: "string", description: "Comma-separated repositories to scope the search to" },
            },
            required: ["g", "a"],
        },
    },
    {
        name: "get_item_info",
        description:
            "Fetch storage metadata for a file or folder by repository key + path. For a folder it lists " +
            "children (so you can browse the tree); for a file it returns size, mimeType, checksums, and the " +
            "download URI. Leave path empty to inspect the repository root.",
        inputSchema: {
            type: "object",
            properties: {
                repoKey: { type: "string", description: "Repository key (e.g. libs-release-local)" },
                path: { type: "string", description: "Path within the repository (default: root)" },
            },
            required: ["repoKey"],
        },
    },
    {
        name: "get_file",
        description:
            "Download the raw contents of a TEXT artifact (e.g. a .pom, package.json, manifest, or properties " +
            "file) by repository key + path. Binary artifacts are detected and returned as metadata only — " +
            "use get_item_info / the download URI for those.",
        inputSchema: {
            type: "object",
            properties: {
                repoKey: { type: "string", description: "Repository key (e.g. libs-release-local)" },
                path: {
                    type: "string",
                    description: "Path to the artifact (e.g. com/acme/app/1.0/app-1.0.pom)",
                },
            },
            required: ["repoKey", "path"],
        },
    },
    {
        name: "list_builds",
        description:
            "List all CI build names published to Artifactory build-info. Returns each build name and when it " +
            "last ran. Use get_build next to drill into a specific build's history.",
        inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
        name: "get_build",
        description:
            "List the build numbers (run history) for a given build name from Artifactory build-info.",
        inputSchema: {
            type: "object",
            properties: {
                buildName: { type: "string", description: "Build name as published to build-info" },
            },
            required: ["buildName"],
        },
    },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    try {
        let result;
        switch (name) {
            case "list_repositories":
                result = await listRepositories(args);
                break;
            case "get_repository":
                result = await getRepository(args);
                break;
            case "search_artifacts":
                result = await searchArtifacts(args);
                break;
            case "gavc_search":
                result = await gavcSearch(args);
                break;
            case "latest_version":
                result = await latestVersion(args);
                break;
            case "get_item_info":
                result = await getItemInfo(args);
                break;
            case "get_file":
                result = await getFile(args);
                break;
            case "list_builds":
                result = await listBuilds();
                break;
            case "get_build":
                result = await getBuild(args);
                break;
            default:
                throw new Error(`Unknown tool: ${name}`);
        }

        return {
            content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
    } catch (err) {
        return {
            content: [{ type: "text", text: `Error: ${err.message}` }],
            isError: true,
        };
    }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("JFrog MCP server running");
