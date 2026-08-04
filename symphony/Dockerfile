# syntax=docker/dockerfile:1.7
#
# Symphony: the opt-in autonomous orchestrator.
#
# Vendored the same way as the opt-in plugins in opencode/Dockerfile — cloned at
# a PINNED ref, built, and baked in, with the resolved commit recorded so a
# running container can say exactly what it is. Bump SYMPHONY_REF deliberately
# and re-test.
#
# This is a SEPARATE image from the opencode one on purpose. Symphony is a
# long-running scheduler with its own lifecycle, and keeping it out of the
# opencode image means the default stack is unchanged by its existence — you
# opt in by adding a compose overlay, not by flipping a flag that alters the
# image everyone else runs.
#
# What lives here does NOT need credentials or egress: symphony talks to the
# opencode server over HTTP and moves files in the queue. The agent does the
# git work, inside the opencode container, where git-guard, squid and the
# credential helper already apply. See docs/SYMPHONY.md.

FROM debian:bookworm-slim AS base

ARG NODE_MAJOR=22
ARG TZ=Europe/Copenhagen

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gosu tzdata \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Corp CA, same contract as the other two images: any *.crt under ./ca/ is
# baked in; an empty dir is fine for local builds.
COPY ca/ /usr/local/share/ca-certificates/corp/
RUN update-ca-certificates

# ---- Build: clone symphony-queue at a pinned ref and compile -----------------
FROM base AS build

# Pin. A tag or a full SHA — never a branch, or the image stops being
# reproducible and "which symphony is running" becomes unanswerable.
ARG SYMPHONY_REF=main
ARG SYMPHONY_REPO=https://github.com/Haugenau20/symphony-queue.git

WORKDIR /build
RUN git clone "${SYMPHONY_REPO}" src \
    && git -C src checkout "${SYMPHONY_REF}" \
    && cd src \
    && npm ci --no-audit --no-fund \
    && npm run build \
    && npm prune --omit=dev \
    && git -C /build/src rev-parse HEAD > /build/.baked-commit

# ---- Runtime ----------------------------------------------------------------
FROM base AS runtime

RUN useradd -m -u 1000 -s /bin/bash dev

WORKDIR /app
COPY --from=build /build/src/dist        /app/dist
COPY --from=build /build/src/node_modules /app/node_modules
COPY --from=build /build/src/package.json /app/package.json
COPY --from=build /build/.baked-commit    /app/.baked-commit

COPY symphony/entrypoint.sh /usr/local/bin/symphony-entrypoint
RUN chmod +x /usr/local/bin/symphony-entrypoint

# No secrets, no egress, no git remote of its own — see the header.
ENV NODE_ENV=production \
    SYMPHONY_WORKFLOW=/config/WORKFLOW.md

ENTRYPOINT ["/usr/local/bin/symphony-entrypoint"]
