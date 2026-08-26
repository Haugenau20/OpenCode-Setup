#!/usr/bin/env bash
# Scaffold a new per-repo workspace by cloning this scaffold and adjusting
# PROJECT_SLUG + OPENCODE_PORT in .env.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <slug> [<host-repo-path>] [<port>]

  slug             Short name; used in compose project + volume names.
  host-repo-path   Path on the host to bind-mount as /workspace.
                   Default: ./repo
  port             Host port for the opencode web/desktop frontend.
                   Default: next free port starting at 4096.

Example:
  $0 myservice ~/code/myservice 4097
EOF
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; exit 0; }
[ "${1:-}" ] || { usage; exit 1; }

SLUG="$1"
REPO_PATH="${2:-./repo}"
PORT="${3:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT%/}-${SLUG}"

if [ -e "${DEST}" ]; then
    echo "${DEST} already exists." >&2
    exit 1
fi

cp -a "${ROOT}" "${DEST}"
rm -rf "${DEST}/.git"

# pick a free port if not given
if [ -z "${PORT}" ]; then
    PORT=4096
    while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}\$"; do
        PORT=$((PORT + 1))
    done
fi

cp "${DEST}/.env.example" "${DEST}/.env"
sed -i \
    -e "s|^PROJECT_SLUG=.*|PROJECT_SLUG=${SLUG}|" \
    -e "s|^OPENCODE_PORT=.*|OPENCODE_PORT=${PORT}|" \
    -e "s|^REPO_PATH=.*|REPO_PATH=${REPO_PATH}|" \
    -e "s|^HOST_UID=.*|HOST_UID=$(id -u)|" \
    -e "s|^HOST_GID=.*|HOST_GID=$(id -g)|" \
    "${DEST}/.env"

cat <<EOF
created ${DEST}
  slug:  ${SLUG}
  port:  ${PORT}
  repo:  ${REPO_PATH}

next:
  cd ${DEST}
  \$EDITOR .env       # fill in LLM_API_KEY and BITBUCKET_PAT
  docker compose up -d
  ./scripts/opencode
EOF
