#!/usr/bin/env bash
# Symphony entrypoint: fix ownership on the bind-mounted queue/workspaces, wait
# for the opencode server, then run the orchestrator as the non-root `dev` user.
set -euo pipefail

log() { printf 'symphony: %s\n' "$*" >&2; }

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
QUEUE_ROOT="${SYMPHONY_QUEUE_ROOT:-/queue}"
WORKSPACES_ROOT="${SYMPHONY_WORKSPACES_ROOT:-/workspaces}"
WORKFLOW="${SYMPHONY_WORKFLOW:-/config/WORKFLOW.md}"
# Compose sets SYMPHONY_OPENCODE_URL; the fallback is for running this image by
# hand. Both derive from the opencode container's INTERNAL port — never
# OPENCODE_PORT, which is the host publication and means nothing on this network.
SERVER_URL="${SYMPHONY_OPENCODE_URL:-http://opencode:${OPENCODE_INTERNAL_PORT:-4096}}"

if [ -f /app/.baked-commit ]; then
    log "symphony-queue $(cat /app/.baked-commit)"
fi

# Match the host user so files the orchestrator writes into the bind-mounted
# queue stay editable from the host — moving a card between folders by hand is
# a first-class operation, not a fallback.
if [ "$(id -u)" = "0" ]; then
    usermod  -u "${HOST_UID}" dev 2>/dev/null || true
    groupmod -g "${HOST_GID}" dev 2>/dev/null || true
fi

# The six state directories must exist and must share one filesystem — the
# claim is a rename(2) between them, which is only atomic within a device.
for dir in todo in-progress review done failed cancelled; do
    mkdir -p "${QUEUE_ROOT}/${dir}"
done
mkdir -p "${WORKSPACES_ROOT}"

if [ "$(id -u)" = "0" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${QUEUE_ROOT}" "${WORKSPACES_ROOT}" || true
fi

if [ ! -f "${WORKFLOW}" ]; then
    log "no workflow at ${WORKFLOW}."
    log "Copy symphony/WORKFLOW.md.example to \$SYMPHONY_CONFIG_PATH/WORKFLOW.md and edit it."
    exit 1
fi

# Wait for the opencode server. Symphony has no egress and no credentials; this
# is the only thing it talks to.
log "waiting for opencode at ${SERVER_URL}..."
for i in $(seq 1 60); do
    if curl -sf "${SERVER_URL}/global/health" >/dev/null 2>&1; then
        log "opencode server ready"
        break
    fi
    if [ "${i}" -eq 60 ]; then
        log "opencode server did not become ready at ${SERVER_URL}"
        exit 1
    fi
    sleep 2
done

# --i-understand-... is symphony's own required acknowledgement that runs are
# unattended. It is not a switch that loosens anything in THIS container: the
# containment lives in the opencode container (git-guard + GIT_REMOTE_ALLOWLIST)
# and, above all, in the scope of the GitLab token. See docs/SYMPHONY.md.
exec gosu dev node /app/dist/main.js \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    "${WORKFLOW}"
