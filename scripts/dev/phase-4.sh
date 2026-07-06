#!/usr/bin/env bash
# Phase 4 (safety gates + persistence) evidence script.
#
# Exercises git-guard in both modes against a local bare repo, checks that
# BITBUCKET_PAT is not written to disk, and verifies session persistence
# survives a restart.
#
# Run from the repo root:  bash scripts/dev/phase-4.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
OUT="scripts/dev/phase-4-output.txt"
: > "${OUT}"

PROJECT_SLUG="default"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
PROJECT_SLUG="${PROJECT_SLUG:-default}"
CONTAINER="opencode-${PROJECT_SLUG}"

run() {
    echo "== $1 ==" | tee -a "${OUT}"
    shift
    "$@" 2>&1 | tee -a "${OUT}"
    rc=$?
    echo "(exit ${rc})" | tee -a "${OUT}"
    echo | tee -a "${OUT}"
}

echo "writing combined evidence to ${OUT}"
echo "phase-4 run at $(date -Iseconds)" | tee -a "${OUT}"

# ---- Set up a fake bare remote on the host that the container can reach
FAKE_REMOTE_HOST=/tmp/fakeremote.git
FAKE_REMOTE_CONT=/tmp/fakeremote.git
run "create fake bare remote" bash -c "
    rm -rf '${FAKE_REMOTE_HOST}'
    git init --bare '${FAKE_REMOTE_HOST}'
"

# We need the fake remote visible inside the container. Easiest way: mount
# /tmp through, but the compose file doesn't. Instead, copy the bare repo
# to a tar, exec into the container, untar.
run "copy fake remote into container" bash -c "
    tar -C /tmp -cf - fakeremote.git | docker exec -i '${CONTAINER}' tar -C /tmp -xf -
    docker exec '${CONTAINER}' ls -la /tmp/fakeremote.git
"

# ---- 4.1 git-guard with ALLOW_REMOTE_GIT=0 (default) -------------------------
run "ensure ALLOW_REMOTE_GIT=0 in env" bash -c "
    grep -q '^ALLOW_REMOTE_GIT=' .env && sed -i 's/^ALLOW_REMOTE_GIT=.*/ALLOW_REMOTE_GIT=0/' .env \
        || echo 'ALLOW_REMOTE_GIT=0' >> .env
    docker compose up -d
    sleep 3
"

run "stage a workspace commit (local-only ops should work)" \
    docker exec "${CONTAINER}" bash -c "
        cd /workspace
        git init -q . 2>/dev/null || true
        echo hello > guard-test.txt
        git add guard-test.txt
        git -c user.email=t@e -c user.name=t commit -q -m 'phase4 test'
        git log --oneline -1
    "

run "git push (expect refusal)" \
    docker exec "${CONTAINER}" bash -c "
        cd /workspace
        git remote remove origin 2>/dev/null || true
        # 'git remote add' itself is gated; bypass by writing config directly
        # so we are specifically testing 'push', not 'remote add'.
        git config remote.origin.url ${FAKE_REMOTE_CONT}
        git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        git push origin HEAD:main
    "

# ---- 4.2 Flip ALLOW_REMOTE_GIT=1 and retry push ------------------------------
run "set ALLOW_REMOTE_GIT=1 and recreate" bash -c "
    sed -i 's/^ALLOW_REMOTE_GIT=.*/ALLOW_REMOTE_GIT=1/' .env
    docker compose up -d --force-recreate opencode
    sleep 3
"

run "git push (expect success)" \
    docker exec "${CONTAINER}" bash -c "
        cd /workspace
        git config remote.origin.url ${FAKE_REMOTE_CONT}
        git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        git push origin HEAD:main
    "

run "prompt should show git:rw" \
    docker exec "${CONTAINER}" bash -c "grep -o 'git:r[wo]' /home/dev/.bashrc"

# ---- 4.3 Bitbucket PAT must not be written to disk inside the container ------
run "search ~/.gitconfig and ~/.git-credentials for PAT material" \
    docker exec "${CONTAINER}" bash -c '
        echo "---- /home/dev/.gitconfig ----"
        cat /home/dev/.gitconfig 2>/dev/null || echo "(no .gitconfig)"
        echo
        echo "---- /home/dev/.git-credentials ----"
        cat /home/dev/.git-credentials 2>/dev/null || echo "(no .git-credentials)"
        echo
        if [ -n "${BITBUCKET_PAT:-}" ]; then
            echo "---- grep for literal PAT value ----"
            grep -RF "${BITBUCKET_PAT}" /home/dev 2>/dev/null \
                && echo "FAIL: PAT found on disk" \
                || echo "OK: PAT not present on disk"
        else
            echo "(BITBUCKET_PAT not set in env; skipping literal grep)"
        fi
    '

# ---- 4.4 Session persistence across restart ----------------------------------
run "write a fake session file" \
    docker exec "${CONTAINER}" bash -c "
        mkdir -p /home/dev/.local/share/opencode/sessions
        echo 'phase4-marker' > /home/dev/.local/share/opencode/sessions/phase4.txt
        ls -la /home/dev/.local/share/opencode/sessions/
    "

run "restart stack, check marker survives" bash -c "
    docker compose down
    docker compose up -d
    sleep 3
    docker exec '${CONTAINER}' cat /home/dev/.local/share/opencode/sessions/phase4.txt
"

# ---- restore .env so the user is not surprised later -------------------------
run "restore .env defaults" bash -c "
    sed -i 's/^ALLOW_REMOTE_GIT=.*/ALLOW_REMOTE_GIT=0/' .env
"

run "tear down" docker compose down

echo "== done ==" | tee -a "${OUT}"
echo "share ${OUT} with the implementation agent." | tee -a "${OUT}"
