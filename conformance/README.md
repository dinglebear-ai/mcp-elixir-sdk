# MCP conformance adapters

These adapters target MCP `2026-07-28` and `2025-11-25` with the pinned harness
`@modelcontextprotocol/conformance@0.2.0-alpha.11`.

MCP Apps evidence is tracked separately in
`mcp-apps-2026-01-26.json`. The core harness does not currently prove browser
hydration, CSP, View/host lifecycle, or same-server App callback routing. Local
SDK tests prove the wire types, validation, exact resource read, binding, and
pure bridge contract. The separate `MCP Apps browser interoperability` workflow
runs on pull requests and can also be dispatched manually. It uses a fresh
official Inspector host whose control API is token-authenticated; the fixture
MCP server is unauthenticated. It uploads
the policy probe, host version, screenshots, console/network
events, and server-side `resources/read`/same-server callback evidence. It is
deliberately not a dependency of package CI.

- `server_adapter.exs` exposes the SDK server over Streamable HTTP and includes
  harness-only diagnostic tools.
- `client_adapter.exs` drives the SDK client from the scenario and context
  environment variables supplied by the harness.
- `scenarios.json` is the historical 2026 qualification ledger. Current CI
  release evidence is generated from the executing commit and archived with
  checksums as `release-evidence.json` plus `SHA256SUMS`.
- `compatibility-2025-11-25.json` records the November server denominator and
  the exact client scenarios, exclusions, and warnings. The `initialize`
  scenario is excluded because this pinned harness returns an invalid JSON-RPC
  response to the client's required initialized notification. The `sse-retry` client
  scenario is recorded as partial and remains a release blocker because harness
  `0.2.0-alpha.11` negotiates unsupported revision `2025-03-26`; it is not
  represented as a passing check.
- `apps_browser_adapter.exs` and `apps_browser_interop.mjs` are fixtures for the
  separate real-host workflow, not Hex package runtime code.
Use the exact commands in `docs/dev-tooling.md`. Harness-only diagnostic tools
are test fixtures, not public SDK behavior.

CI validates both ledgers with `scripts/validate_conformance_ledgers.exs`, runs
every conformance command under a finite timeout, and uploads the server log and
per-scenario output as the `mcp-core-conformance` artifact even after failure.
The artifact is retained for 14 days.

## Evidence validity is not release readiness

The validator accepts truthful incomplete evidence but rejects contradictory
statuses, missing or duplicate required scenarios in either protocol era,
malformed check counts, counted exclusions, and unexplained limitations.
Modern scenario identities and scoring flags are pinned alongside the harness;
deleting a required case or relabeling it out of scope is not a passing result. A passed result must
include nonzero passing checks and no failures, warnings, or skips. The pinned
legacy denominator stays fixed, but its statuses can advance to passed without
changing validator source. No protocol revision is enabled by this tooling.

```sh
# Validate the records and print their blockers.
elixir scripts/validate_conformance_ledgers.exs

# Machine-readable prerequisite state; does not fail solely for known blockers.
elixir scripts/validate_conformance_ledgers.exs --json

# Mandatory static prerequisite before considering a release; exits nonzero
# while any required recorded scenario remains non-passing.
elixir scripts/validate_conformance_ledgers.exs --require-ready
```

A ready ledger is a necessary prerequisite, not release authorization or proof
that its historical results apply to a new commit. Fresh, complete candidate
evidence is still required. CI publishes `ledger-readiness.json`, displays
blockers in its job summary and a warning, and includes readiness in
`release-evidence.json`. Its `releaseReadiness` is `blocked` or `unverified`,
never inferred to be passed merely because selected commands exited zero.

The September 18 reproduction and remaining compatibility decisions are recorded
in [the closeout report](../docs/sessions/2026-09-18-conformance-closeout.md).
