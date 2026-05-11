# Corporate CA

Drop the corporate root certificate(s) here before building the image:

```
ca/corp-root.crt
```

Any file with a `.crt` / `.pem` / `.cer` extension is `.gitignored`, so the
certificate is **never** committed. The build pipeline (TeamCity) is
responsible for retrieving the certificate from your secret store before
running `docker compose build`.

Both the opencode image and the squid image consume this directory:

- opencode: needs the CA so curl / npm / pip / node trust internal HTTPS
- squid: needs the CA so it can validate the LLM / Bitbucket / JIRA TLS
  handshakes when relaying CONNECT tunnels

For local development the directory may be empty — internal HTTPS endpoints
just won't validate. The production image must include the real CA.
