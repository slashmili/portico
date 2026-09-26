# Changelog

## Unreleased

Initial development toward Portico 0.1.0, targeting MCP 2026-07-28.

- Module-based tool declarations with compile-time JSON Schema checks and runtime
  argument validation.
- Plug transport with discovery, tool listing, request metadata validation, and
  application-controlled Logger output.
- Text, structured JSON, and explicit tool-error results.
- Request-scoped progress streaming and form elicitation with signed continuation
  state, response validation, and optional application verification.
- ExUnit helpers and a standalone example tested with the official Python MCP
  client over HTTP.

See the README for current scope and compatibility limits.
