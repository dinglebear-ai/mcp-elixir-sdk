# Conformance closeout, September 18, 2026

## Scope and starting state

Worktree: `conformance-closeout-20260918`, branch
`codex/conformance-closeout-20260918`, based on runtime PR #11 commit
`05b78b5d220b2428acd702a1ad684957dc8e5743`. PR #10 at
`5c56813144a8e9f4bdad62661ccaac66e7527db6` and PR #11 each had nine
successful GitHub checks when this slice began. Neither was merged.

This slice changes evidence tooling and documentation, not SDK wire behavior,
the supported revision registry, credentials, repository identity, or release
publication. The historical qualification ledgers remain unchanged: rerunning
two failures is not a fresh verification of their entire denominators.

## Baseline reproduction

Target: `macpoo.manatee-triceratops.ts.net`, user `jmagar`, Darwin arm64.
Toolchain: Elixir 1.18.4 / OTP 27.2.3, Node 22.18.0.
BEAM limits: `ERL_FLAGS="+S 2:2 +A 2"`.
Harness: `@modelcontextprotocol/conformance@0.2.0-alpha.11`, installed from the
committed lock with `npm ci --ignore-scripts`. Setup and warnings-as-errors
compilation passed. Each probe had a 90-second process-group deadline; neither
reached it. Logs were captured under `/tmp/mcp-sdk-conformance-probe-20260918/`.

```sh
# Run in this worktree after npm ci, mix deps.get and mix compile.
# Repeat once for each scenario; do not retry a protocol failure away.
for scenario in initialize sse-retry; do
  npx --no-install conformance client \
    --command 'env MCP_CONFORMANCE_PROTOCOL_VERSION=2025-11-25 ERL_LIBS=_build/dev/lib elixir conformance/client_adapter.exs' \
    --scenario "$scenario" --spec-version 2025-11-25
done
```

### initialize: blocked, not a pass

At 19:19:21 UTC, the harness recorded one successful initialization check, but
the adapter exited 1 after the notification response:

```elixir
{:error, {:initialized_notification_failed, {:invalid_json_rpc, -32600}}}
```

The harness's summary correctly marks the overall scenario failed despite its
`Passed: 1/1` check counter. The November transport specification requires
accepted notifications to receive HTTP 202 with no body:
[Sending Messages to the Server](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server).
Do not weaken the SDK's response validation to accommodate this fixture.

### sse-retry: blocked before reconnection is exercised

At 19:19:21 UTC, the adapter exited 1 during initialize:

```elixir
{:error, {:invalid_initialize_result, {:unsupported_protocol_version, "2025-03-26"}}}
```

The harness recorded zero passed checks and one failed reconnection check.
This does not establish an SDK reconnection defect: initialization never
selected a supported revision. The error persists even when the harness is
explicitly passed `--spec-version 2025-11-25`.

## What the evidence validator now enforces

The previous validator hardcoded `client.status == incomplete`, permanently
expected `initialize` to be excluded and `sse-retry` to be partial, accepted
contradictory passing check counts, and silently ignored unknown CLI options.
The first regression run recorded 14 tests with 13 failures against that code.

The replacement keeps the required four-scenario legacy denominator fixed but
derives the client summary from real statuses. It validates counts, missing
limitations, duplicates, exclusions and CLI options, and supports a strict
`--require-ready` prerequisite plus machine-readable `--json` output. JSON uses
OTP's decoder so the tool also works on the Elixir 1.17 / OTP 27 CI matrix.

CI surfaces known blockers without converting an honest incomplete ledger into
a failing correctness check. The artifact records `ledgerReadiness` separately
from executed-scenario success and never infers full release qualification.

## Verification of this slice

Final local gates passed on Elixir 1.18.4 / OTP 27.2.3 with two schedulers:
692 tests, zero failures, 15 platform skips; formatting, warnings-as-errors
compilation, strict Credo, Dialyzer, documentation generation, package smoke,
Hex audit, unused-dependency checking and ledger validation all passed. The
14 new regression tests were rerun after fixture-helper cleanup.

Both official server requirement commands exited zero. The November server
reported 81 passed checks and zero failed checks. The July run still lists
failures in the deliberately unscored Tasks extension; these are not described
as passing or silently removed. All eight selected modern client scenarios
and both selected legacy client scenarios exited zero. The two separately
reproduced legacy blockers above remain non-passing. The fixture server was
terminated and reaped by its owning runner after verification.

`actionlint` passed. The actual new workflow summary shell was also extracted
and executed with isolated CI paths: its JSON reported `blocked`, listed both
known blockers, and emitted the intended workflow warning. Validation logs are
under `/tmp/mcp-sdk-ledger-validation-20260918-*`; fresh harness output is under
`/tmp/mcp-sdk-conformance-verification-20260918/`.

## Remaining drive-compat decision

`codex/drive-compat` remains intact at
`3e66695ef6b010405d5dfbd139d715fd5029a2d6`. Its six-file patch adds March and June
2025 adapters globally, while [ADR-008](../adr/0008-dual-version-secure-transports.md)
defines exactly November 2025 and July 2026 support. No explicit approval to
expand that policy was established.

A support expansion needs version-specific wire and capability projection,
negotiation/fallback boundaries, transport lifecycle tests and real-peer
interoperability before claiming those revisions. Preserve the experiment
until that decision; do not silently merge it to make a harness pass.

There is an additional implementation gap: `conformance/client_adapter.exs`
has no `run_scenario("sse-retry", ...)` clause, including on `drive-compat`.
After successful negotiation that scenario reaches the explicit unsupported-
scenario fallback. Adding an older version alone therefore cannot qualify it.
An actual driver needs to exercise and prove reconnection against an approved
revision, separately from correcting the pinned fixture's negotiation.

## Release boundary

The initialization fixture must be corrected upstream or replaced through an
explicitly reviewed harness/scope decision. The SSE fixture, driver and support
policy must be reconciled. Then record the complete required denominator on the
actual candidate and rerun the strict prerequisite, CI and consumer gates.
Neither this report nor green selected CI jobs clears those obligations.
