#!/usr/bin/env bash
# scripts/release.sh — build, tag, and (optionally) push the three release
# images to your registry, using the version in the top-level VERSION file.
#
# Replaces the hand-run docker build/tag/push lines from MAINTAINERS.md
# "Cutting a release". The version is read straight from ./VERSION so the image
# tag, the OCI version label, and /etc/opencode/manifest.json's image_version
# can never drift from each other.
#
# Three images are produced (naming matches the launcher's IMAGE_REGISTRY /
# IMAGE_REGISTRY-squid / IMAGE_REGISTRY-symphony convention and .env.example):
#   opencode : ${IMAGE_REGISTRY}:${VERSION}
#   squid    : ${IMAGE_REGISTRY}-squid:${VERSION}
#   symphony : ${IMAGE_REGISTRY}-symphony:${VERSION}
#
# Usage:
#   ./scripts/release.sh                 # build + tag all three images (no push)
#   ./scripts/release.sh --push          # build + tag, then push (asks first)
#   ./scripts/release.sh --push --latest # also tag/push the moving `latest` tag
#   ./scripts/release.sh --dry-run       # print the docker commands, run nothing
#
# Flags:
#   --push            push the built tags after building (default: build only)
#   --latest          also tag and (with --push) push `latest`
#   --opencode-only   build/push only the opencode image
#   --squid-only      build/push only the squid image
#   --symphony-only   build/push only the symphony image
#   --dry-run         print every docker command instead of running it
#   --yes, -y         skip the confirmation prompt before pushing
#   --help, -h        show this help
#
# Config comes from environment (or the block just below): set IMAGE_REGISTRY to
# your Artifactory path for the opencode-workplace image. OPENCODE_VERSION is
# optional — if set it's passed as a build arg, otherwise the Dockerfile default
# is used. SYMPHONY_REF (the pinned symphony-queue tag/SHA baked into the
# symphony image) is resolved the same way — env var, then symphony/.env,
# then a fallback matching the compose overlay's default — and is validated
# below to make sure it's a pin, never a branch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# env_file_value KEY [FILE] — value of KEY from a dotenv FILE (default ./.env),
# or empty if the file or key is absent. Ignores comments/blank lines, takes the
# last assignment, and strips optional surrounding quotes. It does NOT `source`
# the file (no arbitrary execution) — it just reads the one key.
env_file_value() {
  local key="$1" file="${2:-$ROOT/.env}" line
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1)" || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"      # strip surrounding double quotes
  line="${line%\'}"; line="${line#\'}"      # strip surrounding single quotes
  printf '%s' "$line"
}

# ─────────────────────────────────────────────────────────────────────────────
# Registry / image name — the opencode image's full path; the squid and
# symphony images are the same with a `-squid` / `-symphony` suffix. Resolved
# in this order (first non-empty wins):
#   1. the IMAGE_REGISTRY environment variable (e.g. IMAGE_REGISTRY=… ./release.sh)
#   2. IMAGE_REGISTRY in ./.env  (the same file consumers set — usually all you need)
#   3. the fallback below (edit it if you'd rather hard-code it here)
# ─────────────────────────────────────────────────────────────────────────────
IMAGE_REGISTRY="${IMAGE_REGISTRY:-$(env_file_value IMAGE_REGISTRY)}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-artifactory.internal.example/opencode-workplace}"

# Optional: pin the upstream OpenCode CLI version for the build. Resolved the
# same way (env var, then ./.env); empty ⇒ use the Dockerfile's own default.
OPENCODE_VERSION="${OPENCODE_VERSION:-$(env_file_value OPENCODE_VERSION)}"

# ─────────────────────────────────────────────────────────────────────────────
# Symphony's pinned ref (baked into the symphony image at build time — see
# symphony/Dockerfile). MUST be a tag or a full commit SHA, never a branch, or
# the image stops being reproducible; validated in the preflight section below.
# Resolved in the same order as IMAGE_REGISTRY, but from symphony's own env
# file (kept separate from the root .env — see symphony/.env.example):
#   1. the SYMPHONY_REF environment variable
#   2. SYMPHONY_REF in symphony/.env (gitignored; copy from symphony/.env.example)
#   3. the fallback below, matching docker-compose.symphony.yml's default
# ─────────────────────────────────────────────────────────────────────────────
SYMPHONY_REF="${SYMPHONY_REF:-$(env_file_value SYMPHONY_REF "$ROOT/symphony/.env")}"
SYMPHONY_REF="${SYMPHONY_REF:-v0.4.0}"

# Optional: point the symphony build at a fork. Resolved from the environment
# only (there's no line for it in symphony/.env.example — see there for why);
# empty ⇒ use the Dockerfile's own default.
SYMPHONY_REPO="${SYMPHONY_REPO:-}"

# ── arg parsing ──────────────────────────────────────────────────────────────
DO_PUSH=0 DO_LATEST=0 DRY_RUN=0 ASSUME_YES=0
BUILD_OPENCODE=1 BUILD_SQUID=1 BUILD_SYMPHONY=1

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --push)          DO_PUSH=1 ;;
    --latest)        DO_LATEST=1 ;;
    --opencode-only) BUILD_SQUID=0;    BUILD_SYMPHONY=0 ;;
    --squid-only)    BUILD_OPENCODE=0; BUILD_SYMPHONY=0 ;;
    --symphony-only) BUILD_OPENCODE=0; BUILD_SQUID=0 ;;
    --dry-run)       DRY_RUN=1 ;;
    --yes|-y)        ASSUME_YES=1 ;;
    --help|-h)       usage; exit 0 ;;
    *) echo "release.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$BUILD_OPENCODE" -eq 0 ] && [ "$BUILD_SQUID" -eq 0 ] && [ "$BUILD_SYMPHONY" -eq 0 ]; then
  echo "release.sh: --opencode-only, --squid-only, and --symphony-only are mutually exclusive" >&2
  exit 2
fi

# ── helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run — echo a command, then execute it (or just echo, under --dry-run).
run() {
  printf '   $ %s\n' "$*"
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$@"
}

# ── preflight ────────────────────────────────────────────────────────────────
[ -f VERSION ] || die "no VERSION file at repo root — create one (e.g. 'echo 0.2.0 > VERSION')"
VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || die "VERSION file is empty"

case "$IMAGE_REGISTRY" in
  *CHANGEME*|artifactory.internal.example/*)
    warn "IMAGE_REGISTRY is still the placeholder ('$IMAGE_REGISTRY')."
    warn "Edit scripts/release.sh (or export IMAGE_REGISTRY=…) to your real registry."
    ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

# A production image needs the real corp CA in ca/; an empty ca/ builds fine for
# dev but yields an image that can't validate the corp TLS endpoints.
if ! ls ca/*.crt >/dev/null 2>&1; then
  warn "ca/ has no *.crt — the built image will trust no corp CA."
  warn "Drop the real corp CA into ca/ before a production build (see ca/README.md)."
fi

# SYMPHONY_REF must be a pin (tag or full commit SHA), never a branch — a
# branch-built image isn't reproducible and "which symphony is running"
# becomes unanswerable (see symphony/Dockerfile). Same shape check as
# tests/static.bats runs against symphony/.env.example and the compose
# fallback, so a value that passes here passes there too.
if [ "$BUILD_SYMPHONY" -eq 1 ]; then
  case "$SYMPHONY_REF" in
    v[0-9]*) ;;
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;;
    *) die "SYMPHONY_REF '$SYMPHONY_REF' is not a tag or a full commit SHA — refusing to build a non-reproducible symphony image (see symphony/Dockerfile)" ;;
  esac
fi

OPENCODE_IMAGE="${IMAGE_REGISTRY}:${VERSION}"
SQUID_IMAGE="${IMAGE_REGISTRY}-squid:${VERSION}"
SYMPHONY_IMAGE="${IMAGE_REGISTRY}-symphony:${VERSION}"
OPENCODE_LATEST="${IMAGE_REGISTRY}:latest"
SQUID_LATEST="${IMAGE_REGISTRY}-squid:latest"
SYMPHONY_LATEST="${IMAGE_REGISTRY}-symphony:latest"

info "Version:  $VERSION  (from ./VERSION)"
[ "$BUILD_OPENCODE" -eq 1 ] && info "opencode: $OPENCODE_IMAGE"
[ "$BUILD_SQUID"    -eq 1 ] && info "squid:    $SQUID_IMAGE"
[ "$BUILD_SYMPHONY" -eq 1 ] && info "symphony: $SYMPHONY_IMAGE  (SYMPHONY_REF=$SYMPHONY_REF)"
[ "$DO_LATEST"      -eq 1 ] && info "also tagging: latest"
[ "$DRY_RUN"        -eq 1 ] && info "(dry run — nothing will be built or pushed)"

# ── build + tag ──────────────────────────────────────────────────────────────
oc_build_args=(--build-arg "IMAGE_VERSION=${VERSION}")
[ -n "$OPENCODE_VERSION" ] && oc_build_args+=(--build-arg "OPENCODE_VERSION=${OPENCODE_VERSION}")

symphony_build_args=(--build-arg "SYMPHONY_REF=${SYMPHONY_REF}")
[ -n "$SYMPHONY_REPO" ] && symphony_build_args+=(--build-arg "SYMPHONY_REPO=${SYMPHONY_REPO}")

if [ "$BUILD_OPENCODE" -eq 1 ]; then
  info "Building opencode image…"
  run docker build -f opencode/Dockerfile -t "$OPENCODE_IMAGE" "${oc_build_args[@]}" .
  [ "$DO_LATEST" -eq 1 ] && run docker tag "$OPENCODE_IMAGE" "$OPENCODE_LATEST"
fi

if [ "$BUILD_SQUID" -eq 1 ]; then
  # The squid image carries no manifest and takes no version build arg; its
  # version travels only in the tag.
  info "Building squid image…"
  run docker build -f squid/Dockerfile -t "$SQUID_IMAGE" .
  [ "$DO_LATEST" -eq 1 ] && run docker tag "$SQUID_IMAGE" "$SQUID_LATEST"
fi

if [ "$BUILD_SYMPHONY" -eq 1 ]; then
  # The symphony image carries no manifest and takes no IMAGE_VERSION build
  # arg either; its version travels only in the tag, same as squid. What it
  # does take is SYMPHONY_REF (validated above), same build context as
  # docker-compose.symphony.yml uses for this same Dockerfile.
  info "Building symphony image…"
  run docker build -f symphony/Dockerfile -t "$SYMPHONY_IMAGE" "${symphony_build_args[@]}" .
  [ "$DO_LATEST" -eq 1 ] && run docker tag "$SYMPHONY_IMAGE" "$SYMPHONY_LATEST"
fi

info "Build complete."

# ── push ─────────────────────────────────────────────────────────────────────
if [ "$DO_PUSH" -eq 0 ]; then
  echo
  info "Not pushing (no --push). To push what was just built:"
  latest_hint=""; [ "$DO_LATEST" -eq 1 ] && latest_hint=" --latest"
  echo "     ./scripts/release.sh --push${latest_hint}"
  exit 0
fi

# Collect the exact tags to push.
push_tags=()
[ "$BUILD_OPENCODE" -eq 1 ] && push_tags+=("$OPENCODE_IMAGE")
[ "$BUILD_SQUID"    -eq 1 ] && push_tags+=("$SQUID_IMAGE")
[ "$BUILD_SYMPHONY" -eq 1 ] && push_tags+=("$SYMPHONY_IMAGE")
if [ "$DO_LATEST" -eq 1 ]; then
  [ "$BUILD_OPENCODE" -eq 1 ] && push_tags+=("$OPENCODE_LATEST")
  [ "$BUILD_SQUID"    -eq 1 ] && push_tags+=("$SQUID_LATEST")
  [ "$BUILD_SYMPHONY" -eq 1 ] && push_tags+=("$SYMPHONY_LATEST")
fi

echo
info "About to push:"
for t in "${push_tags[@]}"; do echo "     $t"; done

# Pushing publishes to a shared registry — confirm unless told otherwise or
# there's no terminal to ask at (CI passes --yes).
if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -t 0 ]; then
    printf 'Push these tags? [y/N] '
    read -r reply
    case "$reply" in [Yy]*) ;; *) die "aborted — nothing pushed" ;; esac
  else
    die "refusing to push without a confirmation (pass --yes for non-interactive use)"
  fi
fi

for t in "${push_tags[@]}"; do
  info "Pushing $t…"
  run docker push "$t"
done

info "Pushed $VERSION. Point consumers at IMAGE_TAG=$VERSION and link the CHANGELOG entry."
# `if`, not `[ … ] && …`: as the LAST statement of the script a short-circuited
# `&&` list is the exit status, so `--push --latest` returned 1 on a completely
# successful release — enough to fail a CI job over nothing. The same hazard
# lib/project.sh warns about in the launcher, one level up.
if [ "$DO_LATEST" -eq 0 ]; then
  info "Note: launcher users on IMAGE_TAG=latest won't see this until you also push --latest."
fi
