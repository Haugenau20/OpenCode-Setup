#!/bin/bash
# Launch one of the ten TeamCity MCP instances. OpenCode starts this wrapper
# with a logical instance name; the wrapper maps that instance's stored env
# pair onto the canonical names consumed by index.js.
set -eu

instance="${1:-}"
case "${instance}" in
    teamcity[1-9]|teamcity10) ;;
    *) echo "invalid TeamCity instance: ${instance:-<empty>}" >&2; exit 1 ;;
esac

SVC="${instance^^}"
base_var="${SVC}_BASE_URL"
pat_var="${SVC}_PAT"
base="${!base_var:-}"
pat="${!pat_var:-}"

if [ -z "${base}" ] || [ -z "${pat}" ]; then
    echo "Missing required env vars: ${base_var}, ${pat_var}" >&2
    exit 1
fi

# Each child gets only its own canonical TeamCity credentials. The parent
# OpenCode process still owns the container environment; this prevents one MCP
# process from accidentally selecting another instance's PAT.
for n in {1..10}; do
    unset "TEAMCITY${n}_BASE_URL" "TEAMCITY${n}_PAT" "DISABLE_TEAMCITY${n}_MCP"
done
export TEAMCITY_INSTANCE="${instance}"
export TEAMCITY_BASE_URL="${base}"
export TEAMCITY_PAT="${pat}"

exec node "$(dirname "$0")/index.js"
