#!/usr/bin/env bash
# scripts/check.sh — one-command local gate. Run this before cutting a
# release (see MAINTAINERS.md "Cutting a release", step 0) and before
# pushing anything you want reviewed. This is also the exact set of checks
# meant to become the CI job once CI infra exists (see
# docs/CROSS_REPO_REVIEW_2026-07.md §4.3) — keep this script self-contained
# so lifting it into a pipeline later is a copy, not a rewrite.
#
#   ./scripts/check.sh
#
# Sections run in order; each reports its own PASS/FAIL/WARN/SKIP lines. A
# final summary lists every failed section and the script exits non-zero if
# anything failed. Docker-dependent checks (building both images, `squid -k
# parse`, the MAINTAINERS.md boot smoke test) only run when a Docker daemon
# is actually reachable — otherwise they're listed at the end as reminders
# to run manually before release.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

overall_fail=0
failed_sections=()

section() { printf '\n== %s ==\n' "$*"; }
pass()    { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
warnmsg() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
failmsg() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skipmsg() { printf '  \033[36mSKIP\033[0m %s\n' "$*"; }

# record_result NAME STATUS — STATUS is 0 (pass) or non-zero (fail); tracks
# the overall exit code and which section names to name in the summary.
record_result() {
    local name="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then
        overall_fail=1
        failed_sections+=("$name")
    fi
}

# repo_shell_files — the same file set static.bats checks with `bash -n` /
# shellcheck, kept here too so `./scripts/check.sh` fails fast on a syntax
# error without waiting on a bats fetch.
repo_shell_files() {
    { find "$ROOT" -name '*.sh' \
        -not -path "$ROOT/tests/.bats/*" -not -path "$ROOT/.git/*"
      printf '%s\n' "$ROOT/opencode/git-guard" "$ROOT/scripts/opencode"
    } | sort -u
}

# ---- 1. bash -n across the repo --------------------------------------------
section "bash -n"
rc=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if bash -n "$f" 2>/tmp/check-bashn.$$; then
        :
    else
        failmsg "$f"
        sed 's/^/       /' /tmp/check-bashn.$$
        rc=1
    fi
    rm -f /tmp/check-bashn.$$
done < <(repo_shell_files)
[ "$rc" -eq 0 ] && pass "every shell script parses (bash -n)"
record_result "bash -n" "$rc"

# ---- 2. shellcheck (if present) --------------------------------------------
section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    rc=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if shellcheck --severity=error "$f"; then
            :
        else
            failmsg "$f (see shellcheck output above)"
            rc=1
        fi
    done < <(repo_shell_files)
    [ "$rc" -eq 0 ] && pass "shellcheck (error severity) clean"
    record_result "shellcheck" "$rc"
else
    skipmsg "shellcheck not installed — install it for stricter local checks (not required)"
fi

# ---- 3. jq-validate JSON files ----------------------------------------------
section "JSON validity (jq)"
if command -v jq >/dev/null 2>&1; then
    rc=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if jq empty "$f" >/dev/null 2>&1; then
            :
        else
            failmsg "$f is not valid JSON"
            rc=1
        fi
    done < <(git -C "$ROOT" ls-files '*.json')
    [ "$rc" -eq 0 ] && pass "every tracked *.json file is valid JSON"
    record_result "json" "$rc"
else
    failmsg "jq not installed — cannot validate JSON files"
    record_result "json" 1
fi

# ---- 4. node --check across mcp-servers -------------------------------------
section "node --check (MCP servers)"
if command -v node >/dev/null 2>&1; then
    rc=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if node --check "$f" 2>/tmp/check-node.$$; then
            :
        else
            failmsg "$f"
            sed 's/^/       /' /tmp/check-node.$$
            rc=1
        fi
        rm -f /tmp/check-node.$$
    done < <(find "$ROOT/opencode/mcp-servers" -name '*.js' -not -path '*/node_modules/*')
    [ "$rc" -eq 0 ] && pass "every opencode/mcp-servers/**/*.js parses (node --check)"
    record_result "node --check" "$rc"
else
    failmsg "node not installed — cannot check the MCP server sources"
    record_result "node --check" 1
fi

# ---- 5. tests/run.sh (bats suite) -------------------------------------------
section "tests/run.sh (bats suite)"
if "$ROOT/tests/run.sh"; then
    pass "bats suite green"
    record_result "tests/run.sh" 0
else
    failmsg "bats suite has failures (see above)"
    record_result "tests/run.sh" 1
fi

# ---- 6. docker-dependent checks ---------------------------------------------
section "docker-dependent checks"
docker_ready=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_ready=1
fi

if [ "$docker_ready" -eq 1 ]; then
    rc=0

    echo "  building opencode/Dockerfile (this can take a few minutes) ..."
    if docker build -f opencode/Dockerfile -t opencode-workplace-check:local . >/tmp/check-build-opencode.$$ 2>&1; then
        pass "docker build: opencode/Dockerfile"
    else
        failmsg "docker build: opencode/Dockerfile (see /tmp/check-build-opencode.$$)"
        rc=1
    fi

    echo "  building squid/Dockerfile ..."
    if docker build -f squid/Dockerfile -t opencode-workplace-squid-check:local . >/tmp/check-build-squid.$$ 2>&1; then
        pass "docker build: squid/Dockerfile"
    else
        failmsg "docker build: squid/Dockerfile (see /tmp/check-build-squid.$$)"
        rc=1
    fi

    if docker image inspect opencode-workplace-squid-check:local >/dev/null 2>&1; then
        if docker run --rm opencode-workplace-squid-check:local squid -k parse -f /etc/squid/squid.conf >/tmp/check-squid-parse.$$ 2>&1; then
            pass "squid -k parse"
        else
            failmsg "squid -k parse (see /tmp/check-squid-parse.$$)"
            rc=1
        fi
    else
        skipmsg "squid -k parse (squid image did not build)"
    fi

    if [ -f "$ROOT/.env" ]; then
        echo "  running the MAINTAINERS.md smoke test (PROJECT_SLUG=check-smoke) ..."
        if PROJECT_SLUG=check-smoke OPENCODE_PORT=4098 \
                IMAGE_REGISTRY=opencode-workplace-check IMAGE_TAG=local \
                docker compose up -d >/tmp/check-smoke-up.$$ 2>&1; then
            if "$ROOT/scripts/doctor.sh" >/tmp/check-smoke-doctor.$$ 2>&1; then
                pass "smoke test: docker compose up + doctor.sh"
            else
                failmsg "smoke test: doctor.sh reported failures (see /tmp/check-smoke-doctor.$$)"
                rc=1
            fi
            PROJECT_SLUG=check-smoke docker compose down >/dev/null 2>&1 || true
        else
            failmsg "smoke test: docker compose up failed (see /tmp/check-smoke-up.$$)"
            rc=1
        fi
    else
        warnmsg "no .env — skipping the boot smoke test (needs real LLM credentials); run it manually: see MAINTAINERS.md 'Smoke test'"
    fi

    record_result "docker checks" "$rc"
else
    skipmsg "docker not available or daemon unreachable — the following require a live docker build/boot and were NOT run:"
    echo "    - docker build -f opencode/Dockerfile -t <tag> --build-arg IMAGE_VERSION=<ver> ."
    echo "    - docker build -f squid/Dockerfile -t <tag> ."
    echo "    - squid -k parse -f /etc/squid/squid.conf (inside the built squid image)"
    echo "    - the MAINTAINERS.md 'Smoke test' section (compose up + doctor.sh + scripts/opencode --help)"
    echo "  Run these manually before cutting a release — see MAINTAINERS.md."
fi

# ---- summary -----------------------------------------------------------------
section "summary"
if [ "$overall_fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED:"
    printf '  - %s\n' "${failed_sections[@]}"
fi

exit "$overall_fail"
