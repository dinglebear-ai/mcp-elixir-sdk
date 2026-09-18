# Sprint 2 — Issues and Decisions

Project: MCP_Elixir_SDK (Jira key MES) · Working Procedure pin: Global v2 · Methodology pin: Global v1

This file is the local issue log (WP rule #3, #8). At sprint close it is copied to Confluence as
`Sprint 2 Issues and Decisions`, a child of the Sprint 2 page (WP rule #7 precondition), and the
issues-and-decisions rollup is fired (rule #18).

**Sprint goal (met):** implement the EMFA-requested `handler_opts` seam (per the MES-2 spec), prove it
against EMFA's AC1–AC8 and a real EMFA integration, and publish **v1.1.0** to Hex.

**Tickets (all Done):** MES-3 (implementation) · MES-5 (AC1–AC8 acceptance tests) · MES-6 (external
consumer validation) · MES-4 (v1.1.0 Hex release — last ticket).

---

## Cross-ticket / sprint-level decisions (rollup — WP rule #18)

- **Seam shipped per the MES-2 spec, Option 1 (spec-faithful).** Single `handler_opts` option
  (`keyword()` **or** `(Plug.Conn.t() -> keyword())` factory); no public `{static, factory}` tuple.
  Factory-wins precedence is the documented `Keyword.merge` contract. **Factory-error behaviour:**
  static form fails fast (`ArgumentError`) at `Plug.init/1`; a factory that raises or returns a
  non-keyword fails the session cleanly at `initialize` (HTTP 500 / JSON-RPC -32603, no session
  started, non-leaking `data`).
- **Release version pinned to exactly 1.1.0.** Semver-correct (additive, backward-compatible) **and**
  consumer-constrained — EMFA-12 depends on `{:plexus, "~> 1.1"}`. Published 2026-07-13.
- **Publish is PO-gated.** `mix hex.publish` is the PO's keystroke (Hex password, irreversible). CC
  takes it to a verified dry-run and stops; no publish-capable credential sits next to the agent.
  MES-4 is the **only** ticket that bumps the version and cuts a **release** tag (`v1.1.0` on merge
  commit `f6ccc39`); MES-3/MES-5 used checkpoint tags.
- **Packaged-docs policy (PM ruling, MES-4 cycle 2).** Ship `docs/architecture.md` as an ExDoc extra
  (consumer-relevant: the `:waiting` handshake + seam docs); keep `docs/onboarding.md`
  (contributor-internal) and `docs/handler-opts-identity-seam-spec.md` out of the package, linked via
  GitHub. Fixing the build by *dropping* architecture.md from extras was explicitly rejected.
- **MES-6 doc deltas shipped in 1.1.0** (see MES-4 §1): public Plug option is `server_mod:` (not the
  internal `handler:`); the `:waiting` handshake is documented; the stale Examples link is fixed.

---

## Issues

### Issue: HexDocs build fails from the packaged Hex contents (MES-4 cycle-1 blocker)

**Source Ticket:** MES-4
**Type:** Bug (release-blocker) · **Status:** Fixed in `1e56fe6`
**Description:** `mix.exs` `package.files` excluded `docs/`, but ExDoc `extras` still referenced
`docs/architecture.md` and `docs/onboarding.md`. `mix docs` passed from the repo checkout but **failed
from the unpacked package** (`File.Error … docs/architecture.md`) — which is exactly what HexDocs
builds from after the irreversible publish. Would have shipped a permanently-broken 1.1.0 docs build.
**Fix:** added `docs/architecture.md` to `package.files`; removed contributor-internal
`docs/onboarding.md` from the extras; repointed the two now-unshipped relative links to GitHub.
Verified by building + unpacking the tarball and running `mix docs` from the unpacked contents (clean).
**Recommendation (generalisable release-gate rule):** **verify release artefacts from the packaged
contents, not the working tree.** Candidate for methodology codification (3-instances threshold).

### Issue: Hex now requires account 2FA for write/publish access (encountered at publish)

**Source Ticket:** MES-4
**Type:** Operational / environment · **Status:** Resolved (PO enabled TOTP 2FA)
**Description:** With Hex 2.4+, an account's API key has **read-only** permissions until TOTP
two-factor auth is enabled on the account; publishing returns `key not authorized for this action`.
The PO's existing key was read-only for this reason. Ownership was fine (`jds340+hex@gmail.com`, full).
**Recommendation:** record in release runbooks — enabling TOTP 2FA (hex.pm → Dashboard → Security) is a
one-time precondition for `mix hex.publish`; write ops then prompt for the auth code. No SDK action.

### Issue: Release-prep manifest count mis-stated (MES-4 cycle 1)

**Source Ticket:** MES-4
**Type:** Documentation accuracy · **Status:** Corrected
**Description:** The cycle-1 release-prep page said "76 files". The accurate count is **78 Hex metadata
`files` entries / 67 regular file paths** in `contents.tar.gz` (Reviewer counted 77/66 pre-fix, +1 for
`docs/architecture.md`). Corrected in the cycle-2 page.
**Recommendation:** distinguish metadata entries (include directory entries) from actual file paths when
quoting a manifest count.

### Open question: external examples repo canonical URL

**Source Ticket:** MES-4
**Type:** Question (PO) · **Blocking?:** No
**Description:** The stale `mcp_ex_examples` Examples link was repointed to the SDK repo's own
`#server-examples` anchor (resolves) rather than guessing the external examples repo's post-rename URL.
If a canonical external examples repo exists, its URL could replace the anchor — it ships in permanent
1.1.0 metadata.
**Recommendation:** PO to confirm the external examples repo URL (if any); fold into a future docs pass.

---

## Resolved-in-sprint (no carry)

- **MES-3 Reviewer residual risks** (factory raise/non-keyword behaviour; the default-parity /
  factory-once / reuse / direct-start / PreStarted test matrix) — all asserted in **MES-5** (AC1–AC8,
  8 tests) and re-proven externally in **MES-6**.
- **MES-6 external validation** — EMFA consumed the seam from Git (`cefd843`), removed its Plug fork,
  ran 7 tools over Streamable-HTTP against real Jira (175 tests / 0 failures incl. 10 live
  round-trips). Verdict: works end-to-end, no gaps. The two doc deltas it surfaced shipped in 1.1.0.

---

## Forward notes / next-sprint candidates (from the MES-1 gap register + this sprint)

- **CAND-A** — Client-side OAuth 2.1 authorization (the big gap; separate epic).
- **CAND-C** — Conformance-harness refresh (client adapter drift; wire both modes into CI).
- **CAND-D** — Docs truthfulness sweep (e.g. the external examples-repo link question above).
- **MCP 2026-07-28** stateless-core migration (deferred future epic, ADR-001).
- **Methodology retro:** codify "verify release artefacts from packaged contents, not the working tree"
  as a release-gate rule.
- **EMFA-side (separate):** EMFA-12 reverts EMFA's Git pin → Hex `~> 1.1`; then EMFA's Phoenix-removal
  rewrite.
