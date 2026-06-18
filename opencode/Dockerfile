# syntax=docker/dockerfile:1.7

# ---- Base: OS + tools + corp CA ----------------------------------------------
FROM debian:bookworm-slim AS base

ARG OPENCODE_VERSION=1.17.3
ARG NODE_MAJOR=20
ARG TZ=Europe/Copenhagen

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg tzdata locales gettext-base \
        bash git vim less jq ripgrep fd-find \
        build-essential python3 python3-pip python3-venv \
        openssh-client iproute2 dnsutils \
        sudo gosu \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Node (for opencode runtime + npm-based MCPs)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Corp CA: any *.crt under ./ca/ is baked in. Empty dir is fine in dev builds
# but production builds must include the corporate root certificate.
COPY ca/ /usr/local/share/ca-certificates/corp/
RUN update-ca-certificates

# ---- Plugins build: vendor the opt-in plugins, offline-ready -----------------
# Each plugin is cloned at a PINNED ref, built, and its runtime deps vendored,
# then laid out under /staging/plugins/<name>/ with an `entries` manifest the
# entrypoint reads (`<symlink-name>=<relative/entry/path>` per line). At runtime
# OpenCode 1.16.2 auto-scans `plugin/*.{ts,js}` and imports the symlinked entry
# files directly — no Bun install, no network. Bump a *_REF to update a plugin.
# `base` already carries node 20, git, build-essential, and python3.
FROM base AS plugins-build

# Pin every plugin. superpowers/workspace publish no usable tags, so they pin by
# commit SHA; DCP pins by release tag. Update deliberately and re-test on bumps.
ARG SUPERPOWERS_REF=6fd4507
ARG DCP_REF=v3.1.12
ARG WORKSPACE_REF=4451c688ebfc2cab2eb7bdb4a6a87ad017ea24db

WORKDIR /build
RUN mkdir -p /staging/plugins

# superpowers — zero npm deps; pure-JS plugin entry + bundled skills library.
RUN git clone https://github.com/obra/superpowers.git superpowers \
    && git -C superpowers checkout "${SUPERPOWERS_REF}" \
    && mkdir -p /staging/plugins/superpowers \
    && cp -r superpowers/.opencode superpowers/skills superpowers/package.json \
            /staging/plugins/superpowers/ \
    && printf 'superpowers.js=.opencode/plugins/superpowers.js\n' \
            > /staging/plugins/superpowers/entries \
    && git -C superpowers rev-parse HEAD > /staging/plugins/superpowers/.baked-commit

# dcp — TypeScript plugin built with tsup; runtime deps vendored (WASM tokenizer,
# no native addons). Seeds dcp.jsonc with autoUpdate off so it never pokes npm.
RUN git clone --depth 1 --branch "${DCP_REF}" \
        https://github.com/Opencode-DCP/opencode-dynamic-context-pruning.git dcp \
    && cd dcp && npm install --no-audit --no-fund && npm run build \
       && npm prune --omit=dev && cd .. \
    && mkdir -p /staging/plugins/dcp/seed \
    && cp -r dcp/dist dcp/node_modules dcp/package.json /staging/plugins/dcp/ \
    && printf 'dcp.js=dist/index.js\n' > /staging/plugins/dcp/entries \
    && printf '{\n  "autoUpdate": false,\n  "debug": false\n}\n' \
            > /staging/plugins/dcp/seed/dcp.jsonc \
    && git -C dcp rev-parse HEAD > /staging/plugins/dcp/.baked-commit

# opencode-workspace — keep ONLY the two container-safe plugins. Excludes
# worktree.ts (spawns terminals/sibling containers — impossible in this sandbox)
# and notify.ts (desktop/macOS notifications — useless headless). Deps are plain
# npm packages, vendored alongside the .ts files (which OpenCode/Bun imports).
RUN git clone https://github.com/kdcokenny/opencode-workspace.git workspace \
    && git -C workspace checkout "${WORKSPACE_REF}" \
    && mkdir -p /staging/plugins/opencode-workspace \
    && cp workspace/src/plugin/workspace-plugin.ts \
          workspace/src/plugin/background-agents.ts \
          /staging/plugins/opencode-workspace/ \
    && cp -r workspace/src/plugin/kdco-primitives \
            /staging/plugins/opencode-workspace/ \
    && printf '%s\n%s\n' \
          'workspace-plan.ts=workspace-plugin.ts' \
          'workspace-background.ts=background-agents.ts' \
          > /staging/plugins/opencode-workspace/entries \
    && git -C workspace rev-parse HEAD \
          > /staging/plugins/opencode-workspace/.baked-commit \
    && cd /staging/plugins/opencode-workspace \
    && npm init -y >/dev/null \
    && npm install --no-audit --no-fund \
          @opencode-ai/plugin@1.16.2 @opencode-ai/sdk@1.16.2 \
          zod@3.23.8 unique-names-generator@4.7.1 jsonc-parser@3.3.1

# ---- MCP build: vendor first-party MCP server deps, offline-ready ------------
# The Bitbucket and Jira MCP servers are first-party (committed under
# opencode/mcp-servers/). Install their runtime deps here so nothing hits npm at
# container start — the egress lock would block it. Deps are pure JS (undici,
# zod, the MCP SDK); no native build. `base` already carries node 20 + npm.
FROM base AS mcp-build
COPY opencode/mcp-servers/ /staging/mcp-servers/
RUN set -eu; for d in /staging/mcp-servers/*/; do \
        echo "vendoring deps for ${d}"; \
        (cd "${d}" && npm install --omit=dev --no-audit --no-fund); \
    done

# ---- Runtime: opencode + workplace bundle ------------------------------------
FROM base AS runtime

# Install opencode globally. Version is pinned per build and recorded as an
# OCI label so `docker inspect` shows what's inside.
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# Workplace bundle (agents/skills/commands/mcp) — read-only.
COPY opencode/bundle/ /opt/opencode/bundle/
COPY opencode/policy.yaml /etc/opencode/policy.yaml
COPY opencode/opencode.json /etc/opencode/opencode.json

# Opt-in plugins, built and vendored in the plugins-build stage. The entrypoint
# symlinks the entry files of ENABLED plugins (per disabled.yaml) into the user
# config at start. disabled.yaml.default is the seed for the user's toggle file.
COPY --from=plugins-build /staging/plugins/ /opt/opencode/bundle/plugins/
COPY opencode/disabled.yaml.default /etc/opencode/disabled.yaml.default

# First-party MCP servers (Bitbucket, Jira) with runtime deps vendored in the
# mcp-build stage. The entrypoint wires each into opencode.json only when its
# credentials are present in .env.
COPY --from=mcp-build /staging/mcp-servers/ /opt/opencode/mcp-servers/

# Node/undici trusts the corp CA (system bundle) for HTTPS MCP targets, e.g. a
# TLS Jira. Baked as image ENV — not a runtime export — so it lives in the
# container's stored env and reaches the MCP server no matter which process
# (backend or the TUI's docker exec) spawns it.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# git-guard: block remote git ops unless ALLOW_REMOTE_GIT=1.
COPY opencode/git-guard /usr/local/bin/git-guard
RUN chmod +x /usr/local/bin/git-guard \
    && ln -sf /usr/local/bin/git-guard /usr/local/bin/git

# Non-root user. UID/GID get remapped at start to match the host.
RUN groupadd --gid 1000 dev \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev \
    && echo 'dev ALL=(ALL) NOPASSWD: /usr/sbin/usermod, /usr/sbin/groupmod, /usr/bin/chown' \
         > /etc/sudoers.d/dev-uid-remap \
    && chmod 0440 /etc/sudoers.d/dev-uid-remap

COPY opencode/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default config dir; populated/symlinked by entrypoint at run time.
RUN mkdir -p /home/dev/.config/opencode /home/dev/.local/share/opencode /workspace \
    && chown -R dev:dev /home/dev /workspace

LABEL org.opencontainers.image.title="opencode-workplace" \
      org.opencontainers.image.description="Locked-down OpenCode for internal use" \
      org.opencontainers.image.source="https://bitbucket.example.com/opencode-workplace" \
      opencode.version="${OPENCODE_VERSION}"

EXPOSE 4096
WORKDIR /workspace
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
