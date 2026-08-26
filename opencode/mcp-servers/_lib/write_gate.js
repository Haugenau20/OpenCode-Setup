/**
 * Write gating for the first-party MCP servers.
 *
 * The servers in this image were read-only by construction, which was a real
 * safety property: a compromised or confused agent could not change anything
 * in Bitbucket, Jira, GitLab or Confluence. Publishing work needs that to stop
 * being absolutely true for GitLab — the agent has to open merge requests and
 * answer review comments — so the property becomes conditional instead of
 * disappearing.
 *
 * Same shape as `ALLOW_REMOTE_GIT` in the git guard: a binary switch that is
 * OFF by default, plus an optional destination allowlist that narrows what the
 * switch permits. And the same caveat applies — this is defence in depth, not a
 * security boundary. The agent has a shell and a token; it can `curl` the API
 * directly. What this buys is that write capability is off unless someone
 * deliberately turned it on, and that the tools the model is offered match what
 * the deployment intends.
 *
 * Deliberately dependency-free (no undici, no zod) so it can be unit-tested
 * with plain `node -e`, without any server's node_modules.
 */

/**
 * True when writes are enabled for `service` (e.g. "GITLAB"). Default: off.
 * The variable is `ALLOW_<SERVICE>_WRITE`, matching ALLOW_REMOTE_GIT and
 * ALLOW_CONFLUENCE_WRITE — every switch in this image reads ALLOW_* and only
 * the exact value "1" turns one on.
 */
export function writeEnabled(service, env = process.env) {
    return env[`ALLOW_${service}_WRITE`] === "1";
}

/**
 * Parse a whitespace- or comma-separated allowlist into normalized entries.
 * An empty/unset list means "no restriction beyond the switch itself".
 */
export function parseProjectAllowlist(raw) {
    if (!raw) return [];
    return raw
        .split(/[,\s]+/)
        .map((entry) => normalizeProject(entry))
        .filter((entry) => entry.length > 0);
}

/**
 * Reduce a project reference to a comparable form: lowercase, no surrounding
 * slashes, no trailing `.git`. Accepts numeric ids and `group/sub/project`
 * paths alike, so an allowlist can be written in either style.
 */
export function normalizeProject(project) {
    let value = String(project ?? "").trim().toLowerCase();
    value = value.replace(/^\/+|\/+$/g, "");
    value = value.replace(/\.git$/, "");
    return value;
}

/**
 * Prefix match on a path-segment boundary — the same rule GIT_REMOTE_ALLOWLIST
 * uses, so there is one mental model for both gates. `mygroup` admits
 * `mygroup/service` and `mygroup` itself, and refuses `mygroup-evil/service`.
 */
export function projectAllowed(project, allowlist) {
    if (allowlist.length === 0) return true;
    const target = normalizeProject(project);
    if (!target) return false;
    return allowlist.some((entry) => target === entry || target.startsWith(`${entry}/`));
}

/**
 * Throw unless `project` may be written to. The message names both the switch
 * and the allowlist so a refusal explains itself — an agent that is told
 * exactly why a call was refused stops retrying variations of it.
 */
export function assertWriteAllowed(service, project, env = process.env) {
    if (!writeEnabled(service, env)) {
        throw new Error(
            `${service} writes are disabled. This tool needs ALLOW_${service}_WRITE=1 in .env. ` +
            `Do not attempt to work around this by calling the API directly — the setting is deliberate.`
        );
    }
    const raw = env[`${service}_WRITE_PROJECTS`];
    const allowlist = parseProjectAllowlist(raw);
    if (!projectAllowed(project, allowlist)) {
        throw new Error(
            `${service} writes are not permitted for project "${project}". ` +
            `${service}_WRITE_PROJECTS allows: ${raw}. ` +
            `This is deliberate — report it rather than trying another project or another route.`
        );
    }
}

/**
 * Labels the agent must never set. Where an external orchestrator drives work
 * through issue labels, state IS a `<prefix>::<state>` label and that
 * orchestrator owns every transition — an agent that could relabel its own
 * issue could mark its work reviewed, or enqueue new work for itself in an
 * unbounded loop.
 *
 * So the reserved namespace is refused at the tool boundary rather than merely
 * discouraged in a prompt. A follow-up issue the agent files is unlabelled and
 * therefore invisible to the queue until a human admits it.
 */
export function findReservedLabels(labels, prefix) {
    if (!prefix) return [];
    const needle = `${prefix.toLowerCase()}::`;
    return (labels ?? []).filter((label) =>
        String(label).trim().toLowerCase().startsWith(needle)
    );
}

/** Throw if any label sits in the reserved namespace. */
export function assertNoReservedLabels(labels, prefix) {
    const reserved = findReservedLabels(labels, prefix);
    if (reserved.length > 0) {
        throw new Error(
            `Refusing to set reserved label(s): ${reserved.join(", ")}. ` +
            `The "${prefix}::" namespace is workflow state and is owned by the orchestrator, not by you. ` +
            `File the issue without it; a human decides whether it enters the queue.`
        );
    }
}
