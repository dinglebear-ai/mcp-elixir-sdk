# ADR-010: Rebrand the SDK as Plexus while preserving `MCP.*`

- **Status:** Accepted
- **Date:** 2026-09-17

## Context

The SDK is being prepared for its first Hex publication under a product identity
that matches OTP deployment expectations and our intended long-term repository
coordinate. At the same time, consumers already depend on `MCP.*` as the
protocol/client/server namespace.

Phoenix applications and Depot-hosted MCP services are primary intended
consumers, so branding must be clear while wire behavior and public protocol
module names remain stable.

## Decision

1. Rebrand the SDK identity to **Plexus**.
2. Use OTP app `:plexus` and application/supervisor identity `Plexus.*`.
3. Keep the public `MCP.*` namespace unchanged as the stable protocol/client/server API.
4. Publish canonical source coordinates under `https://github.com/dinglebear-ai/plexus`.

## Consequences

- Runtime ownership and release identity are OTP-native under Plexus.
- Existing `MCP.*` callers do not need namespace migration.
- Phoenix and Depot integrations can adopt Plexus as the package/application
  identity without changing MCP wire semantics.
