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

## Rollout

The repository rename is a separate, explicit operation. Until it is completed
and verified, installation and source links continue to use
`https://github.com/dinglebear-ai/mcp-elixir-sdk`. The OTP identity is already
`:plexus`; it does not depend on changing the repository slug. Evaluation
examples must pin a commit that actually contains that application identity.

The package smoke gate installs both the unpacked candidate and the advertised
README Git snapshot into fresh consumer projects. Each must start `:plexus`,
expose `Plexus.Supervisor`, preserve public `MCP.*` APIs, report its packaged
version, and complete a protocol roundtrip and quickstart calculation.

Fresh-consumer validation exposed a pre-existing dependency metadata defect:
`Req` and `Plug` were marked optional even though bundled modules expand their
structs unconditionally at compile time. Both are required transitive
dependencies; no new package is introduced. `Bandit` remains optional because
consumers choose their server. The bare-consumer smoke explicitly proves
startup without Bandit. A future optional-transport package split would need
its own design rather than suppressing these compilation errors.

Neither a passing consumer smoke test nor the rebrand clears the existing
conformance-ledger release blocker. Repository rename, tagging, and publication
remain separate release operations; do not advertise an unavailable coordinate.

## Consequences

- Runtime ownership and release identity are OTP-native under Plexus.
- Existing `MCP.*` callers do not need namespace migration.
- Phoenix and Depot integrations can adopt Plexus as the package/application
  identity without changing MCP wire semantics.
