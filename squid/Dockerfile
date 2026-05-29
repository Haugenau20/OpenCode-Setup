# syntax=docker/dockerfile:1.7
FROM ubuntu/squid:latest

# Bake the corp CA in so squid trusts internal HTTPS endpoints.
COPY ca/ /usr/local/share/ca-certificates/corp/
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates socat \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY squid/squid.conf /etc/squid/squid.conf
COPY squid/allowlist.d/ /etc/squid/allowlist.d/

EXPOSE 3128
