# Changelog

## Unreleased

### Breaking

- Require Elixir 1.17+ and OTP 27+. Elixir 1.15/1.16 and OTP 26 are no longer supported.

### Security

- Update gun to 2.8 and cowlib to 2.22, fixing CVE-2026-113431 (HTTP/2 HPACK memory exhaustion), CVE-2026-43966, CVE-2026-43969, and CVE-2026-43971.
