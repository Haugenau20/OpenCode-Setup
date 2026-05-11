#!/usr/bin/env bash
# Pre-flight check. Run before reporting anything broken.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "== .env =="
if [ -f .env ]; then
    ok ".env present"
    # shellcheck disable=SC1091
    set -a; . ./.env; set +a

    for var in LLM_API_BASE LLM_API_KEY BITBUCKET_USER BITBUCKET_PAT \
               PROJECT_SLUG OPENCODE_PORT REPO_PATH HOST_UID HOST_GID; do
        if [ -z "${!var:-}" ]; then
            bad "${var} is empty"
        else
            ok "${var} set"
        fi
    done
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
else
    warn "stack not running (docker compose up -d)"
fi

echo
[ "${fail}" -eq 0 ] && echo "all checks passed." || echo "some checks failed."
exit "${fail}"
