# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's **Security advisories** feature instead of opening a public issue. Include the affected version, reproduction steps, and the potential impact. Avoid including real API keys, private media, user UUIDs, server addresses, or other personal information.

## Security recommendations

- Download builds only from a release published by the repository owner, or build the source yourself.
- Grant the app access only to the Immich storage and export folders it needs.
- For optional user-name lookup, use HTTPS and a dedicated API key limited to `user.read`.
- Never include API keys, certificates, NAS credentials, exported media, or Xcode signing profiles in bug reports or commits.
- Review unexpected hidden staging folders before deleting them after an interrupted ZIP export.

## Scope

The app reads user-selected filesystem locations, connects to an optional user-provided Immich endpoint, and invokes the built-in macOS `/usr/bin/ditto` utility to create ZIP archives. Reports involving these boundaries are in scope when they are caused by this project's code.
