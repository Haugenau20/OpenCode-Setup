# syntax=docker/dockerfile:1.7
# Pinned deliberately (resolved 2026-07-03 from
# https://hub.docker.com/v2/repositories/ubuntu/squid/tags) — the ubuntu/squid
# repo does not publish plain numbered release tags, only <squid>-<ubuntu>_beta
# / _edge channel tags plus floating `latest`/`edge` aliases. `latest` resolved
# to this exact image at pin time (squid 6.6, Ubuntu 24.04 base, `_beta`
# channel — long-support, not "unstable"; support window through 05/2029 per
# Docker Hub). Bump with intent: re-resolve the tag list and update both the
# tag and digest below, the same way OPENCODE_VERSION is bumped deliberately.
FROM ubuntu/squid:6.6-24.04_beta@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029

# Bake the corp CA in so squid trusts internal HTTPS endpoints.
COPY ca/ /usr/local/share/ca-certificates/corp/
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates socat \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid/squid.conf /etc/squid/squid.conf
COPY squid/allowlist.d/ /etc/squid/allowlist.d/
COPY squid/entrypoint.sh /usr/local/bin/squid-entrypoint.sh
RUN chmod +x /usr/local/bin/squid-entrypoint.sh

EXPOSE 3128

# Replace the base image's pebble entrypoint: squid runs in the foreground under
# a wrapper that also tails the denied-request access log to the container's
# stdout. squid cannot write that log to /dev/stdout itself because it opens the
# log after dropping to the unprivileged `proxy` user — see squid/entrypoint.sh.
# (The oc-publish sidecar reuses this image but overrides the entrypoint in
# docker-compose, so it is unaffected.)
ENTRYPOINT ["/usr/local/bin/squid-entrypoint.sh"]
CMD []
