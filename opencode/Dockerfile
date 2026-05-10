# syntax=docker/dockerfile:1.7

# ---- Base: OS + tools + corp CA ----------------------------------------------
FROM debian:bookworm-slim AS base

ARG OPENCODE_VERSION=latest
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

# ---- Runtime: opencode + workplace bundle ------------------------------------
FROM base AS runtime

# Install opencode globally. Version is pinned per build and recorded as an
# OCI label so `docker inspect` shows what's inside.
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# Workplace bundle (agents/skills/commands/mcp) — read-only.
COPY opencode/bundle/ /opt/opencode/bundle/
COPY opencode/policy.yaml /etc/opencode/policy.yaml
COPY opencode/opencode.json.tmpl /etc/opencode/opencode.json.tmpl

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
