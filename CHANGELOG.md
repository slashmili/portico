# Changelog

## Unreleased

Initial development toward Portico 0.1.0, targeting MCP 2026-07-28.

- Ordered multi-message text prompts with user/assistant roles and tuple-returning
  constructors and append helpers.

- Optional OAuth resource-server Plug with public discovery metadata, Bearer
  challenges, application-supplied token verification and authenticated assigns.

- Optional tool behavior annotations with compile-time validation and MCP wire names.
- Tool input schemas require an explicit object root at compilation, matching
  the MCP declaration contract.
- Module-based tool declarations with compile-time JSON Schema checks and runtime
  argument validation.
- Plug transport with discovery, tool listing, request metadata validation, and
  application-controlled Logger output.
- Text, structured JSON, and explicit tool-error results, with optional output
  schemas checked at compilation and enforced on successful completed results.
- Request-scoped progress streaming and form/URL elicitation with signed continuation
  state, response validation, and optional application verification.
- Static text resource declarations, discovery, listing, and reading with
  request assigns and direct test helpers.
- ExUnit helpers and a standalone example tested with the official Python MCP
  client over HTTP.

See the README for current scope and compatibility limits.
