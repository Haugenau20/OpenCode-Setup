#!/usr/bin/env bash
# Phase 1 (build + boot) evidence script. Paste the output back to the
# implementation agent. Safe to re-run; tears down the stack at the end.
#
# Run from the repo root:   bash scripts/dev/phase-1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
OUT="scripts/dev/phase-1-output.txt"
: > "${OUT}"

PROJECT_SLUG="default"
if [ -f .env ]; then
    set -a; . ./.env; set +a
fi
PROJECT_SLUG="${PROJECT_SLUG:-default}"
CONTAINER="opencode-${PROJECT_SLUG}"
SQUID="opencode-squid-${PROJECT_SLUG}"
PORT="${OPENCODE_PORT:-4096}"

run() {
    echo "== $1 ==" | tee -a "${OUT}"
    shift
    "$@" 2>&1 | tee -a "${OUT}"
    echo | tee -a "${OUT}"
}

echo "writing combined evidence to ${OUT}"
echo "phase-1 run at $(date -Iseconds)" | tee -a "${OUT}"

run "env sanity" bash -c '
    [ -f .env ] || { echo "no .env — copy .env.example to .env first"; exit 1; }
    grep -E "^(LLM_API_BASE|LLM_API_KEY|PROJECT_SLUG|OPENCODE_PORT|HOST_UID|HOST_GID)=" .env \
        | sed "s/^\(LLM_API_KEY\|BITBUCKET_PAT\)=.*/\1=<redacted>/"
'

run "docker compose build" docker compose build

run "docker compose up -d" docker compose up -d

# Give the entrypoint a moment to finish the eight-step boot. Not a poll —
# one fixed sleep is fine here since we are not waiting on external state.
sleep 5

run "logs: opencode (tail 100)" docker compose logs --tail=100 opencode
run "logs: squid (tail 100)"    docker compose logs --tail=100 squid

run "container ps" docker compose ps

run "id dev (inside container)" docker exec "${CONTAINER}" id dev

run "ls -la /workspace" docker exec "${CONTAINER}" ls -la /workspace

run "ls -la /home/dev/.config/opencode" \
    docker exec "${CONTAINER}" ls -la /home/dev/.config/opencode

run "curl localhost:${PORT} from host" \
    bash -c "curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://localhost:${PORT}"

run "curl localhost:4096 from inside container" \
    docker exec "${CONTAINER}" bash -c \
        "curl -sS --noproxy '*' -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://localhost:4096"

run "second up: docker compose down && up -d" \
    bash -c "docker compose down && docker compose up -d && sleep 5 && docker compose ps"

run "logs after second boot (tail 40)" docker compose logs --tail=40 opencode

run "tear down" docker compose down

echo "== done ==" | tee -a "${OUT}"
echo "share ${OUT} with the implementation agent." | tee -a "${OUT}"
