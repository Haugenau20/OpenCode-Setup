/**
 * Shared plumbing for the first-party MCP servers (opencode/mcp-servers/*).
 *
 * Every server independently re-implemented env validation, the undici
 * ProxyAgent dispatcher, auth-header construction, and MCP tool-error
 * formatting. This module is the one place for that; each server keeps its
 * own tool logic, schemas, and output formatting untouched.
 *
 * ESM resolution walks up from THIS file's directory to find node_modules,
 * so `_lib` carries its own package.json + vendored `undici` (see
 * `_lib/package.json`) rather than borrowing a sibling server's install —
 * it must be able to resolve its own imports regardless of which server
 * requires it first.
 */

import { ProxyAgent, fetch as undiciFetch } from "undici";

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/**
 * Build the undici ProxyAgent every server routes its HTTP calls through
 * (HTTPS_PROXY/HTTP_PROXY, set by docker compose to point at the squid
 * sidecar). Returns undefined when no proxy is configured, which callers
 * pass straight through as `dispatcher: undefined` — undici then falls back
 * to a direct connection.
 *
 * TLS is verified against the corp CA (NODE_EXTRA_CA_CERTS, set in
 * policy.yaml). Do NOT re-add rejectUnauthorized:false here — a locked-down
 * image must not skip certificate verification. If TLS to an internal
 * service fails, the CA isn't in the baked bundle; fix the CA, don't
 * disable the check.
 */
export function makeDispatcher() {
    const proxyUrl = process.env.HTTPS_PROXY || process.env.HTTP_PROXY;
    return proxyUrl ? new ProxyAgent(proxyUrl) : undefined;
}

// ---------------------------------------------------------------------------
// Env validation
// ---------------------------------------------------------------------------

/**
 * Verify every name in `names` is set (non-empty) in process.env. Exits the
 * process with code 1 and a single-line message on stderr if any are
 * missing. The entrypoint only wires a server into opencode.json when its
 * credentials are already present, so this path only fires if something
 * spawns the server directly with an incomplete environment — fail fast and
 * quietly, matching how an unconfigured service is expected to behave.
 */
export function requireEnv(names) {
    const missing = names.filter((name) => !process.env[name]);
    if (missing.length > 0) {
        console.error(`Missing required env vars: ${missing.join(", ")}`);
        process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Auth header builders
// ---------------------------------------------------------------------------

/** `Authorization: Bearer <pat>` — Jira/JFrog/Confluence Data Center. */
export function bearerAuth(pat) {
    return `Bearer ${pat}`;
}

/** `Authorization: Basic <base64(user:pat)>` — general HTTP Basic builder.
 * (Bitbucket's REST API moved to a Bearer PAT; git-over-HTTP still uses Basic,
 * but that lives in the entrypoint's credential helper, not a server. Kept as a
 * general-purpose builder alongside bearerAuth/privateTokenAuth.) */
export function basicAuth(user, pat) {
    return `Basic ${Buffer.from(`${user}:${pat}`).toString("base64")}`;
}

/** `PRIVATE-TOKEN: <pat>` — GitLab's REST API. No encoding; identity
 * wrapper kept for symmetry with the other two builders / call sites. */
export function privateTokenAuth(pat) {
    return pat;
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

/**
 * GET `url` and return `{ status, ok, data }`, parsing the body as JSON only
 * when the response is ok. Matches the Jira/Confluence pattern, where each
 * tool inspects the status code itself for tailored 401/403/404/400
 * messages rather than throwing on a non-2xx response.
 */
export async function jsonGet(url, headers, dispatcher) {
    const res = await undiciFetch(url, { headers, dispatcher });
    return { status: res.status, ok: res.ok, data: res.ok ? await res.json() : null };
}

// ---------------------------------------------------------------------------
// Tool error formatting
// ---------------------------------------------------------------------------

/**
 * Format a caught error as MCP tool-result content. Deliberately excludes
 * err.stack — a Node stack trace is pure token noise for the model, it
 * never explains *why* the request failed, and the message (plus cause,
 * when the caller asks for it) already carries everything actionable.
 */
export function toolError(err, { prefix = "Error", includeCause = false } = {}) {
    let text = `${prefix}: ${err.message}`;
    if (includeCause) text += `\nCause: ${err.cause}`;
    return { content: [{ type: "text", text }], isError: true };
}
