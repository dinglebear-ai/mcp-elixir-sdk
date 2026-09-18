# Spec Addition: `handler_opts` request-identity seam (StreamableHTTP.Plug)

## Document Info
- **Project**: Plexus (Hex package `plexus`)
- **Spec status**: Proposed — **spec only** (implementation tracked in MES-3)
- **Spec'd against source**: **v1.0.2** (`mix.exs @version "1.0.2"`)
- **Change class**: **Additive · backward-compatible · 1.1.0 candidate**
- **Ticket**: MES-2 · **Protocol**: MCP 2025-11-25 (ADR-001) — transport-level, orthogonal to the spec revision
- **Provenance**: dogfooding finding from EMFA (Elixir MCP for Atlassian)

---

## 1. Problem statement

An MCP server exposed over Streamable HTTP normally authenticates **per HTTP request, in the Plug pipeline, before** the MCP session is reached: a bearer token (or similar) is validated and the resulting principal is placed in `conn.assigns` (e.g. `conn.assigns.identity`). A tool handler must act **as that authenticated principal**.

Today there is **no supported way** to carry that request-established identity into the MCP handler:

- `MCP.Transport.StreamableHTTP.Plug` starts one `MCP.Server` per session and, internally, hardcodes the handler spec as `handler: {config.server_mod, []}` (`plug.ex:332`) — the handler's init options are always the empty list.
- `Handler.init/1` therefore never sees any request context.
- `handle_call_tool/3` = `(name, arguments, state)` and `/4` = `(name, arguments, context, state)` (`handler.ex:54,70`) — neither receives the `conn`, headers, or assigns, **by design**.

The only current workaround is to **fork the Plug**, which is a maintenance liability that drifts across SDK versions. Worse, a naïve alternative — passing identity as a **tool-call argument** — is a security anti-pattern: tool arguments are model-controlled, so the model could **spoof the caller**.

This spec adds a first-class, supported seam — **`handler_opts`** — so identity established by the authenticated Plug pipeline is bound, server-side, into the session's handler state, with no Plug fork and no model-visible identity.

---

## 2. The `handler_opts` API

> **Public option name.** The Plug's public options are **`server_mod:`** (the
> handler module) and **`server_opts:`**. `handler:` is the *internal*
> `MCP.Server.start_link/1` key that the Plug constructs for you (it appears in
> the thread path in §2.1 for illustration only) — **do not** pass `handler:`
> when configuring the Plug; consumer-facing configuration always uses
> `server_mod:`.

Add one new option to `MCP.Transport.StreamableHTTP.Plug`:

```elixir
plug =
  MCP.Transport.StreamableHTTP.Plug.new(
    server_mod: MyApp.McpHandler,
    server_opts: [],
    # NEW — either form:
    handler_opts: [region: "eu"]                                  # (a) static keyword
    # handler_opts: fn conn -> [identity: conn.assigns.identity] end  # (b) per-session factory
  )
```

- **(a) Static** — `handler_opts: keyword()`. Passed verbatim to `Handler.init/1`.
- **(b) Factory** — `handler_opts: (Plug.Conn.t() -> keyword())`. Evaluated **once per session at the `initialize` POST**, against that request's `conn`. Its returned keyword list is passed to `Handler.init/1`, capturing request context (typically `conn.assigns` identity) into handler state for the session's lifetime.
- **Type**: `handler_opts :: keyword() | (Plug.Conn.t() -> keyword())`.

The handler consumes it in `init/1` and stores it in state:

```elixir
@impl true
def init(opts) do
  {:ok, %{identity: Keyword.get(opts, :identity), tools: build_tools()}}
end

@impl true
def handle_call_tool(name, args, state) do
  # act as state.identity — NEVER as an identity taken from `args`
  ...
end
```

### 2.1 Thread path (design question 1 — settled against source)

`handler_opts` becomes a field on the `%Plug{}` config struct and its **resolved value** replaces the hardcoded `[]`:

```
Plug.init/1                     store handler_opts on %Plug{}            plug.ex:45-94
POST "initialize"
 └ handle_initialize(conn, …)   ← conn in scope; resolve handler_opts    plug.ex:141
    └ create_session_and_deliver(config, session_id, message, conn)      plug.ex:300  (conn threaded — NEW)
       └ start_session(config, session_id, conn)                         plug.ex:311
          └ start_mcp_server(config, transport_pid, conn)                plug.ex:330
               resolved = resolve_handler_opts(config.handler_opts, conn)
               handler: {config.server_mod, resolved}                    plug.ex:332  (was: [])
             └ MCP.Server.start_link(handler: {mod, resolved}, …)        server.ex:94
                └ MCP.Server.init/1: {mod, opts} = handler_spec          server.ex:226
                    mod.init(opts)                                        server.ex:230
                  └ Handler.init(opts)                                    handler.ex:41
```

`MCP.Server` already pops `{module, opts}` from the `:handler` spec and calls `module.init(opts)` verbatim (`server.ex:226-230`) — **no change is needed below the Plug.** The entire change is: (i) add the `handler_opts` config field, (ii) thread `conn` from `handle_initialize` down to `start_mcp_server`, (iii) resolve and substitute for the `[]`.

`resolve_handler_opts/2` is:

```elixir
defp resolve_handler_opts(fun, conn) when is_function(fun, 1), do: fun.(conn)
defp resolve_handler_opts(list, _conn) when is_list(list), do: list
```

---

## 3. Binding semantics & timing (design question 2 — settled)

- The per-session `MCP.Server` — and therefore `Handler.init/1` — is started **exactly once per session, at the `initialize` POST** (`handle_initialize → start_session`, `plug.ex:141`).
- The factory (form b) is evaluated **at that moment**, against the `initialize` request's `conn`. **Identity is bound once and reused for the session's entire life.**
- Subsequent POSTs on the same session are routed by the ETS `session_id → transport_pid` map (`handle_session_request`, `plug.ex:158`) to the **already-started** server; `Handler.init/1` is **not** re-run. GET (SSE) and DELETE likewise reuse/close the existing session and never re-init the handler.

### 3.1 Per-request identity — explicitly OUT of scope

Streamable HTTP binds session/handler state at `initialize`; there is no per-POST handler re-init. Per-request (as opposed to per-session) identity is therefore **out of scope** for `handler_opts`. If a future need arises for per-call request context, the correct vehicle is `MCP.Server.ToolContext` (the `handle_call_tool/4` context), **not** this seam. This spec does not add that.

---

## 4. Start-path coverage (design question 3 — settled)

- The factory form requires a `conn`, which exists **only** on the Plug's `initialize` request path. The factory is evaluated **inside the Plug** (`handle_initialize`), and only its **keyword result** flows onward.
- **`MCP.Transport.StreamableHTTP.PreStarted` needs no `conn`** and is unchanged — it remains a pure transport adapter carrying `owner` + `pid` (`pre_started.ex:22`). The factory is **fully supported** on the HTTP request path (which uses `PreStarted`), because resolution happens upstream of it.
- **Conn-less start paths** — a directly supervised `MCP.Server.start_link(handler: {mod, opts})` (e.g. stdio, or a user-managed server) — have no request context and therefore support **static `handler_opts` only**. They already accept static opts today via the `{mod, opts}` handler tuple; this spec changes nothing for them.

**Summary:** factory form = Plug / request-scoped path only; conn-less paths = static keyword only.

---

## 5. Merge semantics (design question 4 — settled)

Decision: **factory-wins precedence.** When both a static base and a factory result apply, the effective options are:

```elixir
Keyword.merge(static_base, factory_result)   # factory keys override on conflict
```

Rationale: request-scoped identity must override any build-time default when keys collide. In v1.1.0 the single `handler_opts` option takes **exactly one** form (keyword **or** function), so the SDK performs no runtime merge unless a consumer composes a base inside their own factory; the **specified precedence, whenever a merge does occur, is factory-wins.** This rule is stated now so MES-3 (and any future "base + overlay" extension) has a fixed contract.

---

## 6. Security rationale (design question 5 — settled)

Identity **must** be established by the authenticated Plug pipeline and bound **server-side** into the session at the `initialize` trust boundary — **never** supplied by the model via tool-call arguments.

`handler_opts` is **THE supported request-context → handler-identity mechanism.** It deliberately replaces the anti-pattern of **identity-as-a-tool-parameter**, which is model-spoofable: because tool arguments are chosen by the model, an identity passed there could be forged to impersonate another principal.

Identity arrives via `Handler.init/1` opts — **not** by leaking `Plug.Conn` into `handle_call_tool` — because:

1. **Transport-agnosticism.** `handle_call_tool/3,4` carry no `conn` (`handler.ex:54,70`). Injecting `Plug.Conn` would couple every handler to Plug and break the stdio and in-process transports, which have no `conn`.
2. **Bind once at the trust boundary.** Identity is derived a single time, at the authenticated `initialize`, rather than re-derived on every tool call.
3. **Never model-adjacent.** The principal lives in server-side handler state, invisible to and uninfluenced by the model.

---

## 7. Backward-compatibility guarantee

- The default is **`handler_opts: []`** — identical to today's hardcoded `[]`. Existing consumers that pass no `handler_opts` get **byte-for-byte identical behaviour**; `Handler.init/1` receives `[]` exactly as now.
- The change is **purely additive**: one new optional Plug option, one new `%Plug{}` field, and internal `conn`-threading. No existing option, callback signature, or wire behaviour changes. `Handler.init/1`, `handle_call_tool/3,4`, and the `MCP.Server` handler-spec contract are untouched.
- **Version**: ships as a **minor bump — 1.1.0 candidate** (new public capability, no breaking change).

### 7.1 Observed-vs-source discrepancy (corrected here)

EMFA's vendored `~> 1.0` notes described the Plug as taking `handler: {mod, opts}` with a "hardcoded `{mod, []}`". **Against source v1.0.2 this is corrected:** the Plug's *public* options are **`server_mod`** (required) and **`server_opts`**; `server_opts` today is mined only for `:server_info`, `:capabilities`, `:instructions` (`plug.ex:338`), so any handler args passed via `server_opts` are **silently dropped**. The `handler: {mod, []}` tuple is an **internal** construction in `start_mcp_server/2` (`plug.ex:332`), not a public option. The new seam is therefore named **`handler_opts`** (a new public Plug option), distinct from `server_opts`.

---

## 8. Acceptance (world the spec enables — no Plug fork)

A consumer can, with **no Plug fork**:

1. **Run their own auth Plug before the MCP route** — validate the bearer and set `conn.assigns.identity`.
2. **Configure the Plug** — `handler_opts: fn conn -> [identity: conn.assigns.identity] end`.
3. **Read identity in `Handler.init/1`** into handler state and use it from `handle_call_tool/3`, with **no** tool-arg-supplied identity.
4. **Existing consumers** passing no `handler_opts` behave **exactly as before** (`handler_opts: []`).

Illustrative end-to-end (target design, implemented in MES-3):

```elixir
# 1. auth plug upstream sets conn.assigns.identity
plug = MCP.Transport.StreamableHTTP.Plug.new(
  server_mod: MyApp.McpHandler,
  handler_opts: fn conn -> [identity: conn.assigns.identity] end   # 2
)

defmodule MyApp.McpHandler do
  @behaviour MCP.Server.Handler
  @impl true
  def init(opts), do: {:ok, %{identity: Keyword.fetch!(opts, :identity)}}   # 3
  @impl true
  def handle_call_tool("whoami", _args, state),
    do: {:ok, [%{"type" => "text", "text" => state.identity.subject}], state}  # acts as bound principal, not an arg
end
```

---

## 9. Out of scope

- SDK implementation (→ **MES-3**).
- Client-side OAuth 2.1 (appraisal gap #1 / CAND-A — separate epic, next sprint).
- Per-request (vs per-session) identity, beyond §3.1's explicit ruling.
- Any MCP 2026-07-28 work.
