#!/usr/bin/env bash
# Pre-flight check. Run before reporting anything broken.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Load .env WITHOUT sourcing it: bash would execute an unquoted value like
# `ENABLED_PLUGINS=superpowers dcp ...` as the command `dcp`. Read KEY=VALUE
# lines and export each value verbatim, matching how Docker Compose reads it.
load_env() {
    local file="$1" line
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        case "${line}" in ''|\#*) continue ;; esac
        case "${line}" in [A-Za-z_]*=*) export "${line}" ;; esac
    done < "${file}"
}

fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "== .env =="
if [ -f .env ]; then
    ok ".env present"
    load_env ./.env

    for var in LLM_API_BASE LLM_API_KEY BITBUCKET_USER BITBUCKET_PAT \
               PROJECT_SLUG OPENCODE_PORT REPO_PATH HOST_UID HOST_GID; do
        if [ -z "${!var:-}" ]; then
            bad "${var} is empty"
        else
            ok "${var} set"
        fi
    done

    # Inline `# comment` after a value is kept literally by some docker compose
    # / .env parsers, which silently mangles interpolated settings — e.g. it
    # drops the published port so localhost:4096 becomes unreachable. (Note: the
    # bash `. ./.env` above strips these, so the checks above can't catch it —
    # we scan the raw file.)
    if inline_comments="$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=[^#]*[[:space:]]#' .env)"; then
        bad "inline '#' comments in .env — move them to their own lines (see TROUBLESHOOTING):"
        printf '       %s\n' "${inline_comments}"
    fi
else
    bad ".env missing (cp .env.example .env)"
fi

echo
echo "== corp CA =="
shopt -s nullglob
ca_files=(ca/*.crt ca/*.pem ca/*.cer)
if [ "${#ca_files[@]}" -gt 0 ]; then
    ok "found ${#ca_files[@]} cert(s) in ca/"
else
    warn "no certs in ca/ — internal HTTPS may fail validation"
fi
shopt -u nullglob

echo
echo "== docker =="
if command -v docker >/dev/null; then
    ok "docker on PATH"
    if docker info >/dev/null 2>&1; then
        ok "docker daemon reachable"
    else
        bad "cannot talk to docker daemon (are you in the docker group?)"
    fi
else
    bad "docker not on PATH"
fi

echo
echo "== compose stack =="
PROJECT_SLUG="${PROJECT_SLUG:-default}"
if docker ps --format '{{.Names}}' | grep -qx "opencode-${PROJECT_SLUG}"; then
    ok "opencode container running"

    if docker exec "opencode-${PROJECT_SLUG}" \
            curl -sS --max-time 5 -x http://squid:3128 \
            -o /dev/null -w '%{http_code}\n' "${LLM_API_BASE%/v1}" 2>/dev/null \
            | grep -qE '^(200|301|302|401|403|404)$'; then
        ok "squid reachable from opencode (got a response from LLM host)"
    else
        warn "could not reach LLM host through squid (check allowlist + CA)"
    fi

    if docker ps --format '{{.Names}}' | grep -qx "opencode-publish-${PROJECT_SLUG}"; then
        ok "publisher sidecar running"
    else
        warn "publisher sidecar (opencode-publish-${PROJECT_SLUG}) not running — host localhost:${OPENCODE_PORT:-4096} will be unreachable"
    fi

    if curl -sS --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "http://localhost:${OPENCODE_PORT:-4096}" 2>/dev/null | grep -qE '^(200|401|403)$'; then
        ok "opencode server reachable on host port ${OPENCODE_PORT:-4096}"
    else
        warn "opencode server not reachable on host localhost:${OPENCODE_PORT:-4096} (see TROUBLESHOOTING: Can't reach localhost:4096)"
    fi
else
    warn "stack not running (docker compose up -d)"
fi

echo
echo "== opencode config resolution =="
CONTAINER="opencode-${PROJECT_SLUG}"
CFG=/home/dev/.config/opencode
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    # opencode resolves its global config DIR (agents/skills/commands) from
    # $HOME, independently of the OPENCODE_CONFIG file pin. The server runs as
    # `dev` via gosu, which does NOT reset $HOME, so $HOME must be exported to
    # /home/dev explicitly. If it's /root, the LLM still works (provider comes
    # from the pinned opencode.json) but NO bundled agents/skills/commands load.
    srv_home="$(docker exec "${CONTAINER}" \
        sh -c "tr '\0' '\n' < /proc/1/environ | sed -n 's/^HOME=//p'" 2>/dev/null)"
    if [ "${srv_home}" = "/home/dev" ]; then
        ok "server \$HOME=${srv_home} (opencode reads ${CFG})"
    elif [ -z "${srv_home}" ]; then
        warn "could not read server \$HOME from /proc/1/environ"
    else
        bad "server \$HOME=${srv_home} — opencode is reading ${srv_home}/.config/opencode, not ${CFG}; bundled agents/skills/commands will NOT load. Pull the HOME fix and rebuild (docker compose up -d --build)."
    fi

    # Each bundled kind must have at least one entry that resolves to a real
    # file. `find -L` follows symlinks and skips broken ones, so this also
    # catches dangling links left by an older bundle layout.
    for kind in agents commands; do
        n="$(docker exec "${CONTAINER}" \
            find -L "${CFG}/${kind}" -maxdepth 1 -type f 2>/dev/null | wc -l)"
        if [ "${n:-0}" -gt 0 ]; then
            ok "${kind}: ${n} resolvable item(s) under ${CFG}/${kind}"
        else
            warn "${kind}: nothing resolvable under ${CFG}/${kind}"
        fi
    done

    # Skills are directories containing SKILL.md; a flat skills/<name>.md is
    # silently ignored by opencode.
    sk="$(docker exec "${CONTAINER}" \
        find -L "${CFG}/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l)"
    if [ "${sk:-0}" -gt 0 ]; then
        ok "skills: ${sk} skill(s) with SKILL.md under ${CFG}/skills"
    else
        warn "skills: no <name>/SKILL.md under ${CFG}/skills (a flat skills/<name>.md is ignored by opencode)"
    fi
else
    warn "stack not running — skipping config-resolution checks"
fi

echo
echo "== MCP servers =="
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    # A server is enabled exactly when its credential trio is present (and not
    # force-disabled). Verify the rendered config matches that expectation and
    # that the runtime deps were vendored into the image.
    check_mcp() {
        local svc="$1" want="$2"
        if [ "${want}" = "1" ]; then
            if docker exec "${CONTAINER}" \
                    jq -e ".mcp.${svc}" "${CFG}/opencode.json" >/dev/null 2>&1; then
                ok "${svc}: enabled and wired into opencode.json"
            else
                bad "${svc}: credentials set but NOT wired into opencode.json (see: docker logs ${CONTAINER})"
            fi
            if docker exec "${CONTAINER}" \
                    test -d "/opt/opencode/mcp-servers/${svc}/node_modules"; then
                ok "${svc}: runtime deps vendored"
            else
                bad "${svc}: node_modules missing under /opt/opencode/mcp-servers/${svc} — rebuild (docker compose up -d --build)"
            fi
        else
            ok "${svc}: not configured — skipped (set its <SERVICE>_{BASE_URL,USER,PAT} to enable)"
        fi
    }

    bb_want=0
    [ -n "${BITBUCKET_BASE_URL:-}" ] && [ -n "${BITBUCKET_USER:-}" ] \
        && [ -n "${BITBUCKET_PAT:-}" ] && [ "${DISABLE_BITBUCKET_MCP:-0}" != "1" ] \
        && bb_want=1
    jira_want=0
    [ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_PAT:-}" ] \
        && [ "${DISABLE_JIRA_MCP:-0}" != "1" ] && jira_want=1
    gitlab_want=0
    [ -n "${GITLAB_BASE_URL:-}" ] && [ -n "${GITLAB_USER:-}" ] \
        && [ -n "${GITLAB_PAT:-}" ] && [ "${DISABLE_GITLAB_MCP:-0}" != "1" ] \
        && gitlab_want=1
    jfrog_want=0
    [ -n "${JFROG_BASE_URL:-}" ] && [ -n "${JFROG_PAT:-}" ] \
        && [ "${DISABLE_JFROG_MCP:-0}" != "1" ] && jfrog_want=1

    check_mcp bitbucket "${bb_want}"
    check_mcp jira "${jira_want}"
    check_mcp gitlab "${gitlab_want}"
    check_mcp jfrog "${jfrog_want}"
else
    warn "stack not running — skipping MCP checks"
fi

echo
[ "${fail}" -eq 0 ] && echo "all checks passed." || echo "some checks failed."
exit "${fail}"
