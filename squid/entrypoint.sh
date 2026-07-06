#!/bin/sh
# Entrypoint for the workplace squid proxy.
#
# Why this exists: squid 6.x opens its access log AFTER dropping privileges to
# the unprivileged `proxy` user (cache_effective_user). The container's
# /dev/stdout is a pipe owned by root, so `proxy` cannot reopen it and squid
# aborts at startup with:
#
#   FATAL: Cannot open '/dev/stdout' for writing.
#          The parent directory must be writeable by the user 'proxy' ...
#
# So squid instead logs denied requests to a file in its own proxy-writable log
# directory (see access_log in squid.conf) and we stream that file to the
# container's stdout from here. This script is PID 1, so it keeps the container's
# real stdout fd and `tail` can write to it regardless of who owns the pipe.
# `docker compose logs squid` then shows every denied request.
#
# This replaces the base image's pebble entrypoint. That is fine for our use:
# the corp CA is baked in at build time, and with `cache deny all` / no cache_dir
# squid needs no runtime initialization beyond reading its config.
set -eu

ACCESS_LOG=/var/log/squid/access.log

# Pre-create the log so (a) squid (running as proxy) can open it for writing and
# (b) tail has a file to follow immediately. /var/log/squid is proxy-owned in the
# base image; we set ownership explicitly in case that ever changes.
mkdir -p /var/log/squid
: > "$ACCESS_LOG"
chown proxy:proxy "$ACCESS_LOG" 2>/dev/null || true
chmod 0640 "$ACCESS_LOG" 2>/dev/null || true

# Forward denied-request lines to the container log stream. -F re-opens the file
# across truncation, -n0 skips any pre-existing content. Runs for the life of the
# container; it is reaped when squid (PID 1) exits and the container tears down.
tail -n0 -F "$ACCESS_LOG" &

# Run squid in the foreground (no daemon). cache.log/startup errors go to
# /dev/stderr (opened while squid is still root — see squid.conf) and so also
# reach the container log stream.
exec squid -N -f /etc/squid/squid.conf
