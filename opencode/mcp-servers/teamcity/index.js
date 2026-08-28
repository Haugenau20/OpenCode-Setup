#!/usr/bin/env node
/**
 * Read-only TeamCity MCP server.
 *
 * The same implementation is launched once for each configured instance
 * (teamcity1 ... teamcity10). launch.sh maps the selected instance's URL/PAT
 * onto TEAMCITY_BASE_URL / TEAMCITY_PAT before this process starts.
 * Every upstream request is GET-only and routed through Squid.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { fetch } from "undici";
import { z } from "zod";
import { makeDispatcher, requireEnv, bearerAuth, toolError } from "../_lib/common.js";

requireEnv(["TEAMCITY_BASE_URL", "TEAMCITY_PAT"]);

const INSTANCE = process.env.TEAMCITY_INSTANCE || "teamcity";
const BASE_URL = process.env.TEAMCITY_BASE_URL.replace(/\/+$/, "");
const PAT = process.env.TEAMCITY_PAT;
const dispatcher = makeDispatcher();
const MAX_JSON_CHARS = 1_000_000;
const DEFAULT_LOG_CHARS = 50_000;
const MAX_LOG_CHARS = 100_000;

function headers(accept = "application/json") {
    return {
        Authorization: bearerAuth(PAT),
        Accept: accept,
    };
}

function apiUrl(path, params = {}) {
    const url = new URL(`${BASE_URL}/app/rest${path}`);
    for (const [key, value] of Object.entries(params)) {
        if (value !== undefined && value !== null && value !== "") {
            url.searchParams.set(key, String(value));
        }
    }
    return url;
}

async function tcGet(path, params = {}, responseType = "json") {
    const url = apiUrl(path, params);
    const response = await fetch(url, {
        method: "GET",
        headers: headers(responseType === "text" ? "text/plain" : "application/json"),
        dispatcher,
    });
    const body = await response.text();
    if (!response.ok) {
        const detail = body.replace(/\s+/g, " ").trim().slice(0, 500);
        throw new Error(
            `TeamCity ${INSTANCE} returned HTTP ${response.status} for ${url.pathname}` +
            (detail ? `: ${detail}` : "")
        );
    }
    if (responseType === "text") return body;
    if (body.length > MAX_JSON_CHARS) {
        throw new Error(`TeamCity response exceeded ${MAX_JSON_CHARS} characters; narrow the locator or fields`);
    }
    return body ? JSON.parse(body) : null;
}

function withCount(locator, count) {
    const clean = String(locator || "").trim().replace(/^,+|,+$/g, "");
    return clean ? `${clean},count:${count}` : `count:${count}`;
}

function pathLocator(locator) {
    return encodeURIComponent(String(locator).trim());
}

function jsonResult(data) {
    return {
        content: [{
            type: "text",
            text: JSON.stringify({ instance: INSTANCE, baseUrl: BASE_URL, data }, null, 2),
        }],
    };
}

function register(name, description, schema, handler) {
    server.tool(name, description, schema, async (args) => {
        try {
            return await handler(args);
        } catch (err) {
            return toolError(err, { prefix: `${INSTANCE} MCP error`, includeCause: true });
        }
    });
}

const locatorSchema = z.string().optional().default("").describe(
    "Optional TeamCity locator expression. Use TeamCity locator syntax; count is added separately."
);
const fieldsSchema = z.string().max(2000).optional().describe(
    "Optional TeamCity fields expression to reduce or expand the response."
);
const countSchema = z.number().int().min(1).max(100).optional().default(20).describe(
    "Maximum items to request (default 20, max 100)."
);
const buildIdSchema = z.union([
    z.number().int().positive(),
    z.string().regex(/^\d+$/),
]).describe("Numeric TeamCity build id.");

const server = new McpServer({ name: INSTANCE, version: "1.0.0" });

register(
    "get_server_info",
    "Return version, build, role, time, and web URL for this TeamCity instance.",
    {},
    async () => jsonResult(await tcGet("/server"))
);

register(
    "list_projects",
    "List projects visible to this instance's PAT.",
    { locator: locatorSchema, count: countSchema, fields: fieldsSchema },
    async ({ locator = "", count = 20, fields }) => jsonResult(await tcGet("/projects", {
        locator: withCount(locator, count),
        fields: fields || "count,project(id,name,parentProjectId,archived,webUrl)",
    }))
);

register(
    "get_project",
    "Get one TeamCity project by locator, for example id:MyProject.",
    { locator: z.string().min(1).describe("Project locator, usually id:<project-id>.") },
    async ({ locator }) => jsonResult(await tcGet(`/projects/${pathLocator(locator)}`))
);

register(
    "list_build_configurations",
    "List build configurations (TeamCity build types), optionally filtered with a locator.",
    { locator: locatorSchema, count: countSchema, fields: fieldsSchema },
    async ({ locator = "", count = 20, fields }) => jsonResult(await tcGet("/buildTypes", {
        locator: withCount(locator, count),
        fields: fields || "count,buildType(id,name,projectId,paused,webUrl)",
    }))
);

register(
    "get_build_configuration",
    "Get one build configuration by its TeamCity build type id.",
    { buildTypeId: z.string().min(1).describe("Build configuration id, e.g. Project_Build.") },
    async ({ buildTypeId }) => jsonResult(await tcGet(`/buildTypes/id:${pathLocator(buildTypeId)}`))
);

register(
    "list_builds",
    "List TeamCity builds, optionally filtered with a build locator.",
    { locator: locatorSchema, count: countSchema, fields: fieldsSchema },
    async ({ locator = "", count = 20, fields }) => jsonResult(await tcGet("/builds", {
        locator: withCount(locator, count),
        fields: fields || "count,build(id,buildTypeId,number,status,state,branchName,queuedDate,startDate,finishDate,statusText,webUrl)",
    }))
);

register(
    "get_build",
    "Get detailed information for one TeamCity build id.",
    {
        buildId: buildIdSchema,
        fields: fieldsSchema,
    },
    async ({ buildId, fields }) => jsonResult(await tcGet(`/builds/id:${pathLocator(buildId)}`, {
        fields: fields || "id,buildTypeId,number,status,state,branchName,statusText,queuedDate,startDate,finishDate,webUrl,agent(id,name),triggered,comment,tags,properties,statistics",
    }))
);

register(
    "get_build_log",
    "Read the plain-text build log for a TeamCity build. Output is truncated to a safe size.",
    {
        buildId: buildIdSchema,
        maxChars: z.number().int().min(1000).max(MAX_LOG_CHARS).optional().default(DEFAULT_LOG_CHARS),
    },
    async ({ buildId, maxChars = DEFAULT_LOG_CHARS }) => {
        const log = await tcGet(`/builds/id:${pathLocator(buildId)}/log`, {}, "text");
        const truncated = log.length > maxChars;
        const text = truncated ? `${log.slice(0, maxChars)}\n\n[truncated at ${maxChars} characters]` : log;
        return { content: [{ type: "text", text: `[${INSTANCE} build ${buildId}]\n${text}` }] };
    }
);

register(
    "get_build_tests",
    "List test occurrences for one TeamCity build.",
    { buildId: buildIdSchema, count: countSchema, fields: fieldsSchema },
    async ({ buildId, count = 20, fields }) => jsonResult(await tcGet("/testOccurrences", {
        locator: `build:(id:${buildId}),count:${count}`,
        fields: fields || "count,testOccurrence(id,name,status,duration,details,currentlyMuted,currentlyInvestigated)",
    }))
);

register(
    "get_build_problems",
    "List build problem occurrences for one TeamCity build.",
    { buildId: buildIdSchema, count: countSchema, fields: fieldsSchema },
    async ({ buildId, count = 20, fields }) => jsonResult(await tcGet("/problemOccurrences", {
        locator: `build:(id:${buildId}),count:${count}`,
        fields: fields || "count,problemOccurrence(id,type,identity,details,additionalData,muted,currentlyInvestigated)",
    }))
);

register(
    "get_build_changes",
    "List source changes associated with one TeamCity build.",
    { buildId: buildIdSchema, count: countSchema, fields: fieldsSchema },
    async ({ buildId, count = 20, fields }) => jsonResult(await tcGet("/changes", {
        locator: `build:(id:${buildId}),count:${count}`,
        fields: fields || "count,change(id,version,username,date,comment,webUrl,vcsRootInstance)",
    }))
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`${INSTANCE} MCP connected to ${BASE_URL} (read-only)`);
