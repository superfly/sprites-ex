# Changelog

## Unreleased

### Breaking

- Require Elixir 1.17+ and OTP 27+. Elixir 1.15/1.16 and OTP 26 are no longer supported.

### Changed

- WebSocket connections (exec, control, proxy) use Mint instead of gun. gun and cowlib are no longer dependencies.

### Fixed

- `Sprites.proxy_port/3` now forwards connections. Previously the acceptor sent new sockets to itself and never proxied them.

### Security

- Remove cowlib 2.19, which was affected by CVE-2026-113431 (HTTP/2 HPACK memory exhaustion), CVE-2026-43966, CVE-2026-43969, and CVE-2026-43971.
