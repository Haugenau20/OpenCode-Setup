#!/usr/bin/env bash
# Phase 6 (multi-stack + doctor) evidence script.
#
# Brings up a second stack alongside the first via scripts/new-project.sh
# and confirms there are no port, volume, or container collisions. Runs
# doctor.sh on both. Tears both stacks down.
#
# Run from the repo root:  bash scripts/dev/phase-6.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
OUT="${ROOT}/scripts/dev/phase-6-output.txt"
: > "${OUT}"

PROJECT_SLUG="default"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
PRIMARY_SLUG="${PROJECT_SLUG:-default}"

PARENT="$(dirname "${ROOT}")"
SECOND_DIR="${ROOT%/}-second"

run() {
    echo "== $1 ==" | tee -a "${OUT}"
    shift
    "$@" 2>&1 | tee -a "${OUT}"
    echo | tee -a "${OUT}"
}

echo "writing combined evidence to ${OUT}"
echo "phase-6 run at $(date -Iseconds)" | tee -a "${OUT}"

# ---- bring up the primary stack ----------------------------------------------
run "bring up primary stack" bash -c "docker compose up -d && sleep 3 && docker compose ps"

# ---- scaffold a second stack -------------------------------------------------
if [ -d "${SECOND_DIR}" ]; then
    run "second dir already exists; removing for a clean run" bash -c "
        if [ -f '${SECOND_DIR}/docker-compose.yml' ]; then
            (cd '${SECOND_DIR}' && docker compose down 2>&1 || true)
        fi
        rm -rf '${SECOND_DIR}'
    "
fi

run "scripts/new-project.sh second" \
    bash -c "./scripts/new-project.sh second ./repo 4097"

run "fill secondary .env with same LLM credentials" bash -c "
    # Copy LLM_API_BASE / LLM_API_KEY / BITBUCKET_* from primary so the
    # secondary stack can also boot.
    for k in LLM_API_BASE LLM_API_KEY BITBUCKET_USER BITBUCKET_PAT GIT_USER_NAME GIT_USER_EMAIL; do
        v=\$(grep -E \"^\${k}=\" .env | head -1)
        [ -n \"\${v}\" ] && sed -i \"s|^\${k}=.*|\${v}|\" '${SECOND_DIR}/.env' || true
    done
    grep -E '^(PROJECT_SLUG|OPENCODE_PORT|REPO_PATH|HOST_UID|HOST_GID)=' '${SECOND_DIR}/.env'
"

run "bring up secondary stack" \
    bash -c "(cd '${SECOND_DIR}' && docker compose up -d && sleep 3 && docker compose ps)"

# ---- collision checks --------------------------------------------------------
run "both opencode containers running" \
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
        --filter "name=opencode-"

run "both compose projects have unique networks" \
    docker network ls --filter "name=opencode-" --format 'table {{.Name}}\t{{.Driver}}'

run "both compose projects have unique volumes" \
    docker volume ls --filter "name=opencode-" --format 'table {{.Name}}\t{{.Driver}}'

run "host ports listening" bash -c "ss -ltn '( sport = :4096 or sport = :4097 )' || true"

# ---- doctor on both ----------------------------------------------------------
run "doctor: primary" bash -c "./scripts/doctor.sh; echo exit=\$?"

run "doctor: secondary" bash -c "(cd '${SECOND_DIR}' && ./scripts/doctor.sh; echo exit=\$?)"

# ---- tear down ---------------------------------------------------------------
run "tear down secondary" bash -c "(cd '${SECOND_DIR}' && docker compose down)"
run "tear down primary"   docker compose down

run "remove secondary dir" rm -rf "${SECOND_DIR}"

echo "== done ==" | tee -a "${OUT}"
echo "share ${OUT} with the implementation agent." | tee -a "${OUT}"
