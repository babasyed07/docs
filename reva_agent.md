# AGENTS.md — Reva AI Security SDK

**Audience.** Engineers (and AI coding assistants like Cursor / Claude Code /
Codex) integrating `reva-ai-authz` into an agentic system. This is the canonical
how-to-build-with-this-SDK guide. Read it once before writing integration
code; refer back to it when you need a specific recipe.

**What you get.** Drop-in authorization for every call in an agent chain —
human invoking an agent, agent invoking another agent, agent invoking an
MCP server tool. Two primitives: a decorator on the inbound side, a proxy
on the outbound side. Both call Reva's PDP (Policy Decision Point) before
work happens.

---

## 1. The three primitives

The SDK exposes exactly three things you'll use day-to-day. Everything else
is plumbing.

| Primitive | Where it lives | When you use it |
|---|---|---|
| `@reva_ai_authorise(...)` | `reva_ai.sdk.ai` | On the **inbound** boundary of every agent / MCP server tool. PDP-checks the incoming request before your handler runs. |
| `revaclient.proxy.agent(...)` / `.mcp(...)` / `.api(...)` | `reva_ai.sdk.ai.proxy` | On every **outbound** call to another Reva-protected agent / MCP server. Mints a transaction token and forwards it. |
| `set_caller_identity(...)` | `reva_ai.sdk.ai.adapters` | On entry into a **non-FastAPI** inbound path (worker, queue consumer, A2A SDK route) so the SDK knows who's calling. |

The rest of the SDK is framework adapters (LangChain / LangGraph / CrewAI /
AutoGen / FastMCP) — each is a thin wrapper that maps the three primitives
above onto that framework's native API.

---

## 2. Mental model

```
                       ┌──────────────────────────────────┐
                       │   Reva PDP  (Policy Decision     │
                       │           Point)                 │
                       │                                  │
                       │  POST /pdp/access/v1/             │
                       │    agent/evaluation              │
                       │  POST /pdp/access/v1/             │
                       │    token/enrich                  │
                       └──────────────────────────────────┘
                                       ▲
                                       │ allow / deny
                                       │
   User                                │
    │      Authorization: Bearer <JWT> │
    ▼                                  │
  ┌─────────────────────────┐          │            ┌──────────────────────┐
  │  Agent A  (FastAPI)     │──────────┘ ───────────│  Agent B  (FastAPI)  │
  │                         │   X-Transaction-Token │                      │
  │  @reva_ai_authorise     │   from PDP            │  @reva_ai_authorise  │
  │  ↓                      │   ──────────────►     │  ↓                   │
  │  revaclient.proxy.agent │                       │  revaclient.proxy.   │
  │  ↓                      │                       │       mcp / agent    │
  └─────────────────────────┘                       └──────────────────────┘
```

**Resource types.** There are three:

| Type | What it is | PDP action | rtg/a2a `endpointType` |
|---|---|---|---|
| **Agent** | LLM-driven service callable via HTTP | `invokeAgent` | `Agent` |
| **Tool** | A function the agent calls (in-process) | `invokeTool` | `Agent` (sub-agent) or `MCP` |
| **MCP server** | A Model Context Protocol server | `invokeTool` | `MCP` |

MCP **lifecycle and discovery** methods are NOT policy-checked. The SDK
exempts the following (set `MCP_NO_PDP_METHODS`): `initialize`,
`notifications/initialized`, `ping`, `tools/list`, `prompts/list`,
`resources/list`, `resources/templates/list`, `completion/complete`. Only
**invocations** (`tools/call`, and likewise `prompts/get` /
`resources/read`) hit PDP.

---

## 3. Install

```bash
# Core (FastAPI + httpx + Pydantic)
pip install reva-ai-authz

# With OpenTelemetry tracing
pip install "reva-ai-authz[otel]"

# With test deps (for contributors)
pip install "reva-ai-authz[test]"

# Everything
pip install "reva-ai-authz[all]"
```

The SDK does NOT install LangChain / LangGraph / CrewAI / AutoGen / MCP —
those are your dependencies. The adapters duck-type on framework classes
so the SDK imports cleanly without them.

**Compatibility.** Current release: `reva-ai-authz` **1.2.17**. Requires Python
3.10+ (tested on 3.10 – 3.13). Runtime dependencies are intentionally
minimal: `fastapi>=0.109`, `httpx>=0.25`, `pydantic>=2.5`.

---

## 4. Environment variables

Every service running the SDK must set these. Missing config fails closed.

| Variable | Required | Purpose |
|---|---|---|
| `RTG_URL` | yes | Base URL of the Reva PDP service, e.g. `https://api.your-tenant.reva.ai` |
| `POLICYSTORE_ID` | yes | The policy store this service evaluates against |
| `RTG_AUTH_TOKEN` | yes | Platform API key. Sent as `X-API-Token` on every PDP call. |
| `RTG_DISABLED` | no | A truthy value (`1`/`true`/`yes`/`on`, case-insensitive) disables PDP entirely. **Defaults to false (PDP enabled — fail-closed)**. Never set in production — see §14. |
| `REVA_AI_TOKEN_LEEWAY_SECONDS` | no | Clock-skew tolerance when validating `exp` on PDP-issued transaction tokens. Default `5`. |
| `REVA_AI_LOG_FILE` | no | Path for the SDK's structured log. Default: `reva_ai_sdk.log` next to the install. |
| `REVA_AI_LOG_STDOUT` | no | `1` to also echo SDK logs to stdout. Default `0`. |
| `REVA_AI_LOG_LEVEL` | no | `INFO` (default), `DEBUG`, or `TRACE` (a custom level = 5 that dumps full PDP request/response bodies). |
| `REVA_AI_ALLOW_EXTERNAL_CONTEXT_WRITES` | no | `1`/`true` lets code outside the SDK call the internal `RequestContext.set_*` mutators. For the SDK's own test suite only — never set in application code. |

> **Discovery uses a separate, lowercase env-var family** —
> `reva_ai_rtg_url`, `reva_ai_service_name`, `reva_ai_pod_id`,
> `reva_ai_cluster_name`, `reva_ai_policy_store_id` — distinct from the
> uppercase `RTG_URL` / `POLICYSTORE_ID` used by the auth/proxy hot path.
> See §10.

Put these in `.env` (loaded via `python-dotenv` or your platform's secrets
manager) and resolve them once at startup.

---

## 5. The wire format

This is the contract between your code and PDP. Understanding the shape
makes the rest of the SDK make sense.

**Every PDP call and every agent-to-agent hop uses the same body shape:**

```json
{
  <your business fields, untouched at the root>,
  "rtg/a2a": {
    "id":          "<fresh-uuid-per-hop>",
    "threadId":    "<chain-correlation-id>",
    "promptKey":   "<name of the prompt field in your biz body>",
    "authKey":     "Authorization",
    "issuer":      "<calling agent name>",
    "subject":     { "type": "Agent" | "User", "id": "..." } | null,
    "action":      { "name": "invokeAgent" | "invokeTool" | ... },
    "resource":    { "type": "Agent" | "MCP", "id": "..." },
    "principal":   { "type": "User", "id": "<originating end-user>" } | null,
    "endpoint_url":  "<target URL, e.g. 127.0.0.1:9092/v1/run>",
    "endpointType":  "Agent" | "MCP",
    "originUrl":     "<caller's own URL, see §5.1>",
    "originType":    "Agent",
    "history":     { /* recursive — see §5.2 */ } | null
  }
}
```

**Two invariants you can rely on:**

1. **Your business body is never mutated.** The SDK only adds one new
   key (`rtg/a2a`). If your body has a field named `prompt`, `subject`,
   `history`, etc., it stays in place. PDP only reads from `rtg/a2a`.
2. **The current hop's `rtg/a2a.promptKey` carries the field name**,
   never the resolved value. PDP reads `body[promptKey]` for the live
   prompt text. (The `history` block, which represents prior hops where
   the biz body is gone, carries the resolved `prompt` value frozen.)

### 5.1 `endpoint_url` vs `originUrl`

Two URLs travel in `rtg/a2a` — one identifies the **target** of this call,
one identifies the **caller**.

| Field | Names | When set | What PDP does with it |
|---|---|---|---|
| `endpoint_url` + `endpointType` | The **target** URL (where this call is going) | Set by the SDK on every outbound hop. Echoed on inbound eval (the receiving agent already knows its own URL). | URL-prefix lookup against the policy store's entities table → resolves the **resource** entity. |
| `originUrl` + `originType` | The **caller's** own URL | Set on outbound hops only when the calling agent itself received an inbound `endpoint_url` (i.e., a previous hop named it). Empty on first-hop (user → agent). | URL-prefix lookup → resolves the **principal** (caller) entity. |

**Resolution precedence on PDP** (both endpoints):

```
Cedar `principal` (= the caller, in Cedar syntax):
  1. originUrl present → URL-prefix entity lookup → use that id
  2. originUrl absent  → use rtg/a2a.subject (the body's named subject)

Cedar `resource` (= the target):
  1. endpoint_url present → URL-prefix entity lookup → use that id
  2. endpoint_url absent  → use rtg/a2a.resource (the body's named resource)
```

This means you can register your entities in the policy store **either by
URL or by friendly name** — both flows work, and they can be mixed in the
same chain.

### 5.2 `history` chain

The `history` block carries the chain of prior hops. Each hop is the same
shape as the current hop's `rtg/a2a` (minus the per-hop fields like `id`,
`promptKey`, `authKey`). Recursive — `history.history.history…` builds the
full chain.

The deepest level always has `history: null`. Use this for chain-of-custody
audit (multi-hop traces in the decision log).

### 5.3 First-hop body (user → agent)

A non-Reva caller (a browser, mobile app, integration test) doesn't know
about `rtg/a2a`. It sends only its business body:

```json
{ "query": "Pull up MSCU7841293 — customer is escalating." }
```

The receiving agent's `@reva_ai_authorise` decorator constructs the
`rtg/a2a` block from the access token + the decorator's `agent_name`
kwarg + the request URL. First-hop's `originUrl` is empty (no inbound
rtg/a2a to inherit from); PDP falls back to the access token's claims.

---

## 6. Quick start — 5-minute hello

A single FastAPI agent that calls one downstream agent:

```python
# main.py
import os
from fastapi import FastAPI, Request
from pydantic import BaseModel

from reva_ai.sdk.ai import reva_ai_authorise
from reva_ai.sdk.ai.proxy import revaclient

app = FastAPI()

class ChatRequest(BaseModel):
    query: str

@app.post("/v1/chat")
@reva_ai_authorise(
    agent_name="hello-agent",
    auth_key="Authorization",     # header carrying the caller's bearer token
    prompt_key="query",           # field in body carrying the prompt
)
async def chat(body: ChatRequest, request: Request):
    # Inbound PDP check passed. RequestContext is now populated.

    # Optional: call another Reva-protected agent
    resp = await revaclient.proxy.agent(
        endpoint_url=f"{os.environ['BILLING_AGENT_URL']}/v1/run",
        method="POST",
        body={"text": body.query},
        prompt_key="text",
        resource_id="billing-agent",   # PDP id of the target agent
    )
    return resp.json()
```

`.env`:
```
RTG_URL=https://api.your-tenant.reva.ai
POLICYSTORE_ID=525a1450-8e00-4bee-8bf5-e309f61c1924
RTG_AUTH_TOKEN=<your platform API key>
```

That's the complete integration. Everything below this is variations on
this theme.

---

## 7. Inbound authorization

### 7.1 FastAPI HTTP agent

Decorate the route, NOT the application. Order matters — `@reva_ai_authorise`
must be **below** `@app.post(...)` so it sees the FastAPI request.

```python
from fastapi import FastAPI, Request
from reva_ai.sdk.ai import reva_ai_authorise

app = FastAPI()

@app.post("/v1/run")
@reva_ai_authorise(
    agent_name="shipment-supervisor-agent",
    auth_key="Authorization",
    prompt_key="query",
    action="invokeAgent",                 # default
    conversation_key="threadId",          # optional
    conversation_key_location="body",     # "body" | "header" | "query"
    principal_claim="cognito:username",   # override which JWT claim becomes principal id
)
async def run(body: dict, request: Request):
    # PDP allowed. Your handler runs.
    return {"reply": "..."}
```

**Decorator kwargs:**

| Kwarg | Required | Purpose |
|---|---|---|
| `agent_name` | one of\* | HTTP agent's PDP id (Cedar resource id). Selects the **HTTP route** code path. |
| `tool_name` | one of\* | MCP tool/server PDP id. Selects the **MCP tool** code path; `action` auto-defaults to `invokeTool`. |
| `crew_name` | one of\* | CrewAI **Crew factory** PDP id (decorate a function annotated `-> Crew`). Selects the **CrewAI** code path. |
| `auth_key` | recommended | Header name carrying the caller's bearer token. Almost always `"Authorization"`. |
| `prompt_key` | recommended | Path to the prompt text in the body. Simple field name (`"query"`) or JSON-path (`"params.message.parts[0].text"`). |
| `action` | no | PDP action name. Default `"invokeAgent"` (HTTP) / `"invokeTool"` (MCP). |
| `conversation_key` / `conversation_key_location` | no | Where to read a thread/conversation id from — `conversation_key_location` is `"header"` or `"body"`. Enables final-turn RTG recording (see §15). |
| `principal_claim` | no | JWT claim name to use as the principal id. Default: `sub`. Common override: `"cognito:username"`. Forwarded as the `X-Principal-Claim` header on every hop. **Strict**: if set and the claim is missing/non-string, PDP denies — there is no fallback to `sub`. |
| `agent_type` | no | **HTTP routes only.** Marks the agent's framework — must be `"crew"` or `"langgraph"` (any other value raises `ValueError`). Stored for audit/future use; does **not** change PDP evaluation. **Do NOT use this for MCP** — MCP servers use `tool_name`. |

\* Pass **exactly one** of `agent_name`, `tool_name`, or `crew_name`. Passing
zero or more than one raises `ValueError`.

**What the decorator does, in order:**

1. Read the bearer token from the configured `auth_key` header.
2. Read the body, extract any inbound `rtg/a2a` block, stash on
   `RequestContext`.
3. Build the PDP `/agent/evaluation` body — your biz body untouched at
   root + a freshly-built `rtg/a2a` block with subject/principal/history
   inherited from the inbound rtg/a2a (if present) and the access token
   (if first hop).
4. POST to PDP. On **allow**: hand control to your function. On **deny**:
   raise `RevaAuthorizationError` (FastAPI turns it into a structured 403).

### 7.2 FastMCP server

Decorate each tool function. The decorator detects FastMCP context and
PDP-checks `tools/call`:

```python
from mcp.server.fastmcp import FastMCP
from reva_ai.sdk.ai import reva_ai_authorise

mcp = FastMCP("billing-tools")

@mcp.tool()
@reva_ai_authorise(
    tool_name="reva-rate-mcp",    # the MCP server's PDP id (shared by all its tools)
    action="invokeTool",          # optional — auto-set when tool_name is used
    prompt_key="origin_code",
)
def get_freight_quote(origin_code: str, destination_code: str) -> dict:
    ...
```

> **Note:** MCP tools are identified by `tool_name`, **not**
> `agent_name`/`agent_type`. The `tool_name` value is the MCP **server's**
> PDP entity id — all tools on one server share it (the server is the unit
> of policy, not the individual tool).

The Reva-internal `rtg/a2a` argument that `proxy.mcp` injects into the
tool-call body is stripped before your tool function runs, so your tool
only ever sees its declared parameters (plus an optional `headers`).

`tools/list`, `prompts/list`, `resources/list`, `initialize` are NOT
gated — only `tools/call`.

### 7.3 Non-FastAPI inbound (workers, A2A SDK, queue consumers)

Some routing frameworks (e.g. `a2a-sdk`'s `A2AFastAPIApplication`) own
their own routes and don't give you a function to decorate. Or you have
a queue worker. Or a CLI process. In those cases, use the adapter API:

```python
from reva_ai.sdk.ai.adapters import (
    set_caller_identity,
    authorise_inner_call_async,
)

# 1. At inbound: seed RequestContext from your transport.
async def inbound_middleware(request):
    body_bytes = await request.body()
    request._body = body_bytes  # re-cache so downstream can re-read

    inbound_rtg = None
    try:
        data = json.loads(body_bytes) if body_bytes else {}
        if isinstance(data, dict):
            rtg = data.get("rtg/a2a")
            if isinstance(rtg, dict):
                inbound_rtg = dict(rtg)
    except Exception:
        pass

    raw_token = (
        request.headers.get("x-transaction-token")
        or request.headers.get("authorization", "")
    ).strip()

    set_caller_identity(
        agent_name="log-agent",
        agent_type="Agent",
        auth_token=raw_token,
        domain=request.headers.get("domain", ""),
        username=request.headers.get("username", ""),
        inbound_rtg_a2a=inbound_rtg,   # critical — carries subject/principal/history
    )

# 2. In the executor / handler: call PDP.
class MyExecutor:
    async def execute(self, request_context, queue):
        await authorise_inner_call_async(
            resource_name="log-agent",
            resource_type="Agent",
            action="invokeAgent",
        )
        # ... your business logic ...
```

`set_caller_identity` is the public seam between your transport code
and the SDK. It sets the same `RequestContext` state that
`@reva_ai_authorise` would have set on a FastAPI route.

### 7.4 Skipping authorization for specific paths

You can't selectively skip the decorator — if you don't want PDP on a
route, just don't decorate it. Routes that are purely public (health
checks, readiness probes, public marketing endpoints) should be left
undecorated.

---

## 8. Outbound proxy

Three variants, one shape. Always replace raw `httpx` calls between
Reva-protected services with these.

### 8.1 `revaclient.proxy.agent` — call another Reva-protected agent

```python
from reva_ai.sdk.ai.proxy import revaclient

# Sync (auto-detected from your call site)
resp = revaclient.proxy.agent(
    endpoint_url="http://billing-agent.internal/v1/run",
    method="POST",
    body={"text": "Get freight quote..."},
    prompt_key="text",
    resource_id="billing-agent",     # the target's PDP id
)
print(resp.json())

# Async
resp = await revaclient.proxy.agent(...)

# Streaming
async with revaclient.proxy.agent(..., stream=True) as r:
    async for line in r.aiter_lines():
        ...
```

**Parameters** (all keyword-only):

| Param | Default | Purpose |
|---|---|---|
| `endpoint_url` | — (required) | Target agent URL. |
| `method` | `"GET"` | HTTP method — pass `"POST"` for typical `/v1/run` calls. |
| `body` | `None` | Payload. `dict`/`list` → sent as JSON and (for dicts) wrapped in the `rtg/a2a` envelope; other types → raw bytes. |
| `prompt_key` | `None` | Field name carrying the prompt (falls back to the inbound decorator's value). |
| `resource_id` | `None` | The target's PDP id (`rtg/a2a.resource`). |
| `auth_key` | `None` | Per-call override of the header name carrying the user JWT. |
| `headers` | `None` | Extra headers, merged last. |
| `stream` | `False` | Return a streaming context manager instead of a buffered response. |
| `transport` | `"httpx"` | Only `"httpx"` is supported (anything else raises `NotImplementedError`). |

Sync vs async is auto-detected: if an event loop is running you get an
awaitable (or `async with` for streams); otherwise you get a blocking
`httpx.Response` (or `with` for streams). There is no flag to force it.

**What it does:**

1. POST to PDP `/token/enrich` with a body containing your business
   payload + a freshly-built `rtg/a2a` envelope.
2. On allow, PDP returns a short-lived **transaction token** (a JWE).
3. SDK validates the token's `exp` locally.
4. SDK POSTs to `endpoint_url` with your biz body wrapped in the
   same `rtg/a2a` shape and the token in `X-Transaction-Token`.
5. Returns the downstream response as an `httpx.Response`.

On deny: `RevaAuthorizationError` is raised; no downstream call is
made.

### 8.2 `revaclient.proxy.mcp` — call an MCP tool

```python
result = await revaclient.proxy.mcp(
    tool=langchain_mcp_tool,             # LangChain MCP tool object
    arguments={"container_id": "MSCU7841293"},
    mcp_client="http://127.0.0.1:9101/mcp",
    resource_id="reva-carrier-mcp",      # MCP server's PDP id
    endpoint_protected=True,             # run the full Reva-mediated MCP lifecycle
    headers=RequestContext.get_propagation_headers(),  # see §9.6
)
```

> ⚠️ **`endpoint_protected` defaults to `False`.** When `False` (or when
> `RTG_DISABLED` is set), `proxy.mcp` invokes the tool **directly with no
> PDP check** — it just calls the underlying client tool. You **must** pass
> `endpoint_protected=True` to get the Reva-mediated, PDP-authorized MCP
> lifecycle. This is the single most common way to accidentally bypass
> policy on MCP calls.

**Key parameters** (keyword-only):

| Param | Default | Purpose |
|---|---|---|
| `tool` | — (required) | A client tool object (LangChain MCP adapter / CrewAI tool) **or** a non-empty tool-name string (string form needs `endpoint_protected=True` + `mcp_client`). |
| `arguments` | — (required) | The tool-call arguments (`dict`, or a JSON-object string). |
| `resource_id` | `None` | MCP server's PDP id (`rtg/a2a.resource`; falls back to the tool name). |
| `endpoint_protected` | `False` | **Set `True`** to run the PDP-mediated MCP lifecycle (see warning above). |
| `mcp_client` | `""` | MCP URL / `MultiServerMCPClient` / connection dict / JSON. |
| `client_type` | `"langchain"` | `"langchain"` or `"crewai"`. |
| `transport` | `"streamable_http"` | `streamable_http` (default), `sse`, or `stdio`. `websocket` raises `NotImplementedError`. |
| `headers` | `None` | Extra headers merged onto the connection. |
| `mcp_session_id` | `None` | Reuse an existing MCP session (skips `initialize`). |
| `protocol_version` | `"2024-11-05"` | MCP protocol version sent on `initialize`. |
| `client_name` / `client_version` | `"reva-ai"` / `"1.0.0"` | `clientInfo` on `initialize`. |
| `timeout` | `30.0` | Per-call HTTP timeout (seconds). |
| `stdio_command` / `stdio_env` | `None` | argv + env for the `stdio` transport. |
| `sse_post_url` | `None` | JSON-RPC POST URL for the `sse` transport. |

When `endpoint_protected=True` the SDK runs the full MCP lifecycle for you
(`initialize` → `notifications/initialized` → `tools/call`) over the chosen
transport, carrying the transaction token. The Reva metadata travels only
inside `params.arguments["rtg/a2a"]` — never at the JSON-RPC top level.

### 8.3 `revaclient.proxy.api` — call an arbitrary external API

```python
async with revaclient.proxy.api(
    endpoint_url="https://internal-api.example.com/users",
    method="GET",
    headers={"Accept": "application/json"},
) as response:
    response.raise_for_status()
    return response.json()
```

Same PDP path as `proxy.agent`, but the body shape is preserved as-is
(no `rtg/a2a` reshaping — for APIs that aren't Reva-aware).

**Parameters** (keyword-only): `endpoint_url` (required), `method`
(`"GET"`), `body`, `query_params` (sent as URL query string), `headers`,
`stream` (`False`), `endpoint_type` (`"Api"` — the destination type sent to
PDP), `auth_key`, `prompt_key`. The PDP **action is derived from the HTTP
method**: `GET`/`HEAD`/`OPTIONS` → `read`, `POST`/`PUT`/`PATCH` → `write`,
`DELETE` → `delete`.

`revaclient.proxy.http(...)` is an alias of `revaclient.proxy.api(...)`.

### 8.4 Choosing the right proxy

| Calling | Use |
|---|---|
| Another agent's HTTP `/v1/run` (or similar) | `proxy.agent` |
| MCP server tool | `proxy.mcp` |
| Backend HTTP API that isn't Reva-aware | `proxy.api` |

**Rule of thumb:** any HTTP call leaving your Reva-protected service
should go through one of these three. Raw `httpx` / `requests` calls
bypass policy.

**One exception**: a public API gateway in front of your protected agent
should forward `Authorization` verbatim and let the receiving agent's
inbound decorator handle PDP. Don't double-wrap at the gateway layer.

---

## 9. Framework adapters

### 9.1 LangChain (Runnables + Tools)

```python
from reva_ai.sdk.ai.adapters.langchain import protect_runnable, protect_tool
from langchain.tools import tool

# Protect a sub-runnable
protected_planner = protect_runnable(
    planner_chain,
    agent_name="planner-subagent",
)

# Protect a LangChain @tool
@tool
async def lookup_customer(customer_id: str) -> str:
    ...

protected_lookup = protect_tool(lookup_customer, tool_name="lookup_customer")
```

When the outer FastAPI route is wrapped by `@reva_ai_authorise`, the
caller's token, identity, and trace context flow through
`RequestContext` and the adapter picks them up automatically.

### 9.2 LangGraph (StateGraph + nodes)

```python
from langgraph.graph import StateGraph, START, END
from reva_ai.sdk.ai.adapters.langgraph import protect_node, protect_state_graph

@protect_node(agent_name="planner-node")
async def planner(state, config):
    ...

builder = StateGraph(MyState)
builder.add_node("planner", planner)
builder.add_edge(START, "planner")
builder.add_edge("planner", END)
graph = builder.compile()

# Optional: wrap the whole compiled graph
protected_graph = protect_state_graph(graph, agent_name="full-graph")
```

For agent-to-agent HTTP hops from inside a node, use the outbound proxy:

```python
async def consult_billing(state, config):
    resp = await revaclient.proxy.agent(
        endpoint_url=f"{settings.billing_agent_url}/v1/run",
        method="POST",
        body={"text": state["last_message"]},
        prompt_key="text",
        resource_id="billing-agent",
    )
    return {"billing": resp.json()}
```

### 9.3 CrewAI (Agents + Crews)

CrewAI has first-class support in the **core** decorator:

```python
from crewai import Agent, Crew
from reva_ai.sdk.ai import reva_ai_authorise

@reva_ai_authorise(agent_name="research-agent")
def make_research_agent() -> Agent:
    return Agent(role="Researcher", goal="Investigate", backstory="...")

@reva_ai_authorise(crew_name="research-crew")
def make_research_crew() -> Crew:
    return Crew(agents=[make_research_agent()], tasks=[...])
```

The decorator detects the CrewAI return type and consults PDP **before**
CrewAI materializes tasks — a deny short-circuits crew startup.

### 9.4 AutoGen (ConversableAgent + GroupChat)

```python
from autogen import ConversableAgent
from reva_ai.sdk.ai.adapters.autogen import (
    protect_agent,
    protect_function_tool,
    protect_group_chat_manager,
)

assistant = ConversableAgent(name="assistant", llm_config={...})
protected = protect_agent(assistant, agent_name="assistant")

@protect_function_tool(tool_name="lookup_customer")
def lookup_customer(customer_id: str) -> str:
    ...

# GroupChat manager
manager = GroupChatManager(...)
protected_manager = protect_group_chat_manager(manager, agent_name="orchestrator")
```

### 9.5 a2a-sdk (`A2AFastAPIApplication`)

`A2AFastAPIApplication` owns its own routes — you can't decorate the
handlers directly. Use middleware + `authorise_inner_call_async`:

```python
from fastapi import FastAPI, Request
from a2a.server.apps import A2AFastAPIApplication
from a2a.server.agent_execution import AgentExecutor
from reva_ai.sdk.ai.adapters import authorise_inner_call_async, set_caller_identity

class MyExecutor(AgentExecutor):
    async def execute(self, request_context, queue):
        await authorise_inner_call_async(
            resource_name="my-agent",
            resource_type="Agent",
            action="invokeAgent",
        )
        # ... business logic ...

def build_app() -> FastAPI:
    a2a_app = A2AFastAPIApplication(
        agent_card=...,
        http_handler=DefaultRequestHandler(agent_executor=MyExecutor(), ...),
    )
    fastapi_app = a2a_app.build()

    @fastapi_app.middleware("http")
    async def reva_auth_middleware(request: Request, call_next):
        import json
        body_bytes = await request.body()
        request._body = body_bytes  # re-cache for the A2A handler

        inbound_rtg = None
        if body_bytes:
            try:
                d = json.loads(body_bytes)
                if isinstance(d, dict) and isinstance(d.get("rtg/a2a"), dict):
                    inbound_rtg = dict(d["rtg/a2a"])
            except Exception:
                pass

        raw_token = (
            request.headers.get("x-transaction-token")
            or request.headers.get("authorization")
            or ""
        ).strip()

        set_caller_identity(
            agent_name="my-agent",
            agent_type="Agent",
            auth_token=raw_token,
            domain=request.headers.get("domain", ""),
            username=request.headers.get("username", ""),
            inbound_rtg_a2a=inbound_rtg,
        )
        return await call_next(request)

    return fastapi_app
```

### 9.6 Propagating identity to non-Reva transports

`@reva_ai_authorise` and the proxy handle identity propagation for you. When
you must step outside them — a custom HTTP client, a background task, or a
transport the SDK doesn't wrap — use the one supported propagation API:

```python
from reva_ai.sdk.ai.utils.context import RequestContext

headers = RequestContext.get_propagation_headers()
# Returns the session token (Authorization: Bearer ... OR X-Transaction-Token),
# X-Principal-Claim, the domain/username audit headers, and the W3C trace
# context (traceparent / tracestate / baggage). Returns {} outside a request.
```

Don't hand-roll header forwarding or read `Authorization` yourself —
`get_propagation_headers()` is the supported seam and keeps the wire contract
correct as the SDK evolves.

---

## 10. Service discovery (optional)

Beyond per-call authorization, the SDK can **self-register** a FastAPI service
with the Reva control plane so it appears in the platform's inventory of agents
and MCP servers. This is optional and independent of the authorization hot
path.

```python
from fastapi import FastAPI
from reva_ai.sdk.ai.discovery import reva_ai_discover, get_discovery_info

app = FastAPI()

# As a one-shot call …
reva_ai_discover(app, service_type="Agent", service_name="shipment-supervisor-agent")

# … or as a decorator on a factory that returns the app:
@reva_ai_discover(service_type="MCP")
def build_app() -> FastAPI:
    return FastAPI()
```

`service_type` is the workload kind — `"Agent"` or `"MCP"`. On registration the
SDK POSTs a discovery record to `{reva_ai_rtg_url}/discovery-logs` and caches a
`DiscoveryConfig` on `app.state` (retrievable with `get_discovery_info(request)`).
Discovery failures are swallowed — they never break your service.

**Discovery configuration env vars** (note the lowercase naming — these are
distinct from the uppercase auth/proxy vars in §4):

| Variable | Purpose |
|---|---|
| `reva_ai_rtg_url` | Base URL for the discovery endpoint (required for discovery). |
| `reva_ai_service_name` | Default service name when not passed to `reva_ai_discover`. |
| `reva_ai_pod_id` | Pod identifier recorded in the discovery payload. |
| `reva_ai_cluster_name` | Cluster name recorded in the discovery payload. |
| `reva_ai_policy_store_id` | Policy store id recorded in the discovery payload. |
| `RTG_AUTH_TOKEN` | If set, sent as `X-API-Token` on the discovery POST. |

Public API (`reva_ai.sdk.ai.discovery`): `reva_ai_discover`,
`get_discovery_info`, `DiscoveryConfig`.

---

## 11. Worked example — 4-agent chain

Walking through one full chat turn to make the moving pieces concrete.

**Topology:**

```
   browser                 supervisor          compliance          compliance-mcp
   ──────────┐ ────────► ─────────────────► ────────────────► ─────────────────
   (user JWT)              (PDP-protected      (PDP-protected      (PDP-protected
                            HTTP agent)         HTTP agent)         MCP server)
```

**Code, supervisor:**

```python
@app.post("/v1/run")
@reva_ai_authorise(
    agent_name="shipment-supervisor-agent",
    auth_key="Authorization",
    prompt_key="query",
)
async def run(body: dict, request: Request):
    # User → supervisor PDP eval already happened.
    # Now consult compliance:
    resp = await revaclient.proxy.agent(
        endpoint_url="http://compliance-agent:9092/v1/run",
        method="POST",
        body={"text": f"compliance check for {body['container_id']}"},
        prompt_key="text",
        resource_id="compliance-agent",
    )
    return resp.json()
```

**Code, compliance-agent:**

```python
@app.post("/v1/run")
@reva_ai_authorise(
    agent_name="compliance-agent",
    auth_key="Authorization",
    prompt_key="text",
)
async def run(body: dict, request: Request):
    # supervisor → compliance PDP eval already happened.
    # Now call compliance-mcp:
    result = await revaclient.proxy.mcp(
        tool=compliance_mcp_tool,
        arguments={"container_id": "MSCU7841293"},
        mcp_client="http://compliance-mcp:9103/mcp",
        resource_id="reva-compliance-mcp",
        endpoint_protected=True,
    )
    return {"reply": result}
```

**PDP calls fired during one chat turn:**

| # | Endpoint | Caller's view | What PDP evaluates |
|---|---|---|---|
| 1 | `/agent/evaluation` | supervisor inbound | `User::john → invokeAgent → Agent::shipment-supervisor-agent` |
| 2 | `/token/enrich` | supervisor → compliance | `Agent::shipment-supervisor-agent → invokeAgent → Agent::compliance-agent` |
| 3 | `/agent/evaluation` | compliance inbound | (same — re-evaluated on the receiver side) |
| 4 | `/token/enrich` | compliance → MCP | `Agent::compliance-agent → invokeTool → MCP::reva-compliance-mcp` |
| 5 | `/agent/evaluation` | MCP server inbound (if FastMCP `@reva_ai_authorise` is applied) | (same as #4) |

Audit dashboard shows one row per call. The chain is traceable end-to-end
via `threadId`.

---

## 12. Policy authoring (Cedar)

PDP evaluates Cedar policies. For the chain above to succeed, your
policy store needs:

```cedar
// 1. john can invoke the supervisor
permit (
    principal == User::"john",
    action    == Action::"invokeAgent",
    resource  == Agent::"shipment-supervisor-agent"
);

// 2. supervisor can invoke compliance
permit (
    principal == Agent::"shipment-supervisor-agent",
    action    == Action::"invokeAgent",
    resource  == Agent::"compliance-agent"
);

// 3. compliance can invoke its MCP server
permit (
    principal == Agent::"compliance-agent",
    action    == Action::"invokeTool",
    resource  == MCP::"reva-compliance-mcp"
);
```

**Tip on entity ids.** Policies match the entity's Cedar `uid.id` field
from your entity table. You can register entities by **URL** or by
**friendly name** — the SDK works with either:

| Registration | Cedar uid.id | Policy refers to | Resolved via |
|---|---|---|---|
| URL-keyed | `127.0.0.1:9092/v1/run` | `Agent::"127.0.0.1:9092/v1/run"` | `originUrl` / `endpoint_url` URL-prefix match |
| Name-keyed | `compliance-agent` | `Agent::"compliance-agent"` | `rtg/a2a.subject.id` / `rtg/a2a.resource.id` fallback |

You can mix-and-match within a chain. Just keep your policies in sync
with whichever id form you registered.

---

## 13. Exception handling

```python
from reva_ai.sdk.ai.utils.exceptions import (
    RevaAIError,                  # base class for every SDK error (alias: FastAPISDKError)
    RevaAuthorizationError,       # PDP deny / missing creds (also a FastAPI HTTPException)
    AuthenticationError,          # authentication / token-format problem
    AuthorizationError,           # base for authorization failures
    ConfigurationError,           # missing RTG_URL / POLICYSTORE_ID
    ValidationError,              # invalid input (URL / header validation)
    InvocationError,              # downstream invocation failure
    NetworkError, TimeoutError,   # subclasses of InvocationError
    CircuitBreakerError,          # subclass of InvocationError
)
from reva_ai.sdk.ai.adapters import AdapterError  # non-PDP adapter-layer failures
```

**Hierarchy:**

```text
RevaAIError                         (alias: FastAPISDKError)
├── AuthenticationError
├── AuthorizationError
│   └── RevaAuthorizationError      (+ fastapi.HTTPException)
├── ValidationError
├── ConfigurationError
└── InvocationError
    ├── NetworkError
    │   └── TimeoutError
    └── CircuitBreakerError

AdapterError                        (in reva_ai.sdk.ai.adapters — adapter-layer errors)
```

Only `RevaAuthorizationError` carries an HTTP `status_code` (401 for missing
credentials, 403 for a policy deny). The rest are plain Python exceptions.

FastAPI handles `RevaAuthorizationError` automatically — it inherits
from `HTTPException`. The response body is:

```json
{
  "detail": {
    "message": "PDP denied inbound request",
    "decision": false,
    "hop": "inbound",
    "pdp": {
      "decision": false,
      "context": { "reason": "authorization denied by policy" }
    }
  }
}
```

Manual handling if you need it:

```python
try:
    result = await revaclient.proxy.agent(...)
except RevaAuthorizationError as e:
    log.warning(
        "PDP denied: status=%s reason=%s code=%s hop=%s",
        e.status_code, e.reason, e.code, e.hop,
    )
    raise
```

`RevaAuthorizationError` fields:

| Field | Meaning |
|---|---|
| `status_code` | 401 (missing creds) or 403 (PDP deny) |
| `decision` | The string PDP returned (`"false"` / `"deny"`) |
| `reason` | Human-readable, from PDP response body |
| `code` | Machine-readable error code, when PDP provides one |
| `hop` | `"inbound"` or `"outbound"` |
| `pdp_response` | The full PDP JSON for further inspection |

---

## 14. Security model — what the SDK guarantees

1. **Fail-closed by default.** Missing `RTG_URL` / `POLICYSTORE_ID`
   raises at first PDP call. `RTG_DISABLED` defaults to false. **Do not
   set `RTG_DISABLED=true` in production** — it disables PDP entirely
   and emits a one-shot WARNING at startup. Useful only for local
   integration testing where PDP isn't reachable.
2. **Transaction tokens are short-lived.** PDP (RTG) issues each
   transaction token with a small TTL. The SDK validates the token's `exp`
   locally — with a configurable clock-skew leeway
   (`REVA_AI_TOKEN_LEEWAY_SECONDS`, default `5`) — before sending it
   downstream, so an already-expired token never reaches the next agent.
3. **Customer body is never mutated.** The SDK only **adds** one key
   (`rtg/a2a`) to your outbound body. Your existing fields, including
   any named `prompt`, `history`, `subject`, `principal`, etc., are
   left untouched.
4. **Context is SDK-internal.** `RequestContext.set_*` mutators raise
   `PermissionError` when called from outside the SDK's own modules.
   Use `set_caller_identity()` (the public adapter) for non-FastAPI
   inbound paths instead.
5. **Token leakage protection.** SDK logs redact `Authorization`,
   `X-Transaction-Token`, `Cookie`, and any JSON field whose name
   contains `token`, `authorization`, `secret`, or `cookie`.
6. **Deny reasons are surfaced.** `RevaAuthorizationError.reason` /
   `.code` / `.pdp_response` carry PDP's deny payload so callers and
   operators can diagnose policy failures without grepping PDP logs.
7. **Platform key is separated from the user identity.** When
   `RTG_AUTH_TOKEN` is set, the SDK sends it as the `X-API-Token` header for
   perimeter authentication and leaves `Authorization` carrying the
   end-user JWT that PDP needs for policy evaluation. The two are never
   conflated.

---

## 15. Observability

### 15.1 Audit logs

Every PDP decision (allow OR deny) lands in Reva's decision-log
pipeline. From the SOC dashboard you'll see one row per hop:

```
timestamp  principal           type    action       resource              type        decision
12:11:02   john                User    invokeAgent  shipment-supervisor   Agent       Allow
12:11:02   shipment-supervisor Agent   invokeTool   reva-carrier-mcp      MCP         Allow
12:11:05   shipment-supervisor Agent   invokeAgent  compliance-agent      Agent       Allow
12:11:08   compliance-agent    Agent   invokeTool   reva-compliance-mcp   MCP         Deny
```

Same `threadId` ties a chain together.

### 15.2 OpenTelemetry (optional)

`pip install "reva-ai-authz[otel]"`. The SDK then emits spans:

- `reva.agent.authorize` (server) — inbound decorator
- `reva.proxy.tokenEnrich` (client) — outbound proxy PDP enrichment
- `reva.proxy.downstream` (client) — the outbound call to the target after enrichment

Standard attributes: `reva.agent.name`, `reva.action`,
`reva.resource.id`, `reva.resource.type`, `reva.decision`, `reva.hop`,
`reva.deny.reason`, `reva.deny.code`, `http.target`.

On deny, span status → ERROR with the deny reason.

W3C trace context (`traceparent` / `tracestate` / `baggage`) propagates
on every outbound call regardless of whether OTel is installed.

### 15.3 SDK structured log

The SDK writes a JSONL log to `REVA_AI_LOG_FILE` (default `reva_ai_sdk.log`).
Useful grep markers:

Every line is prefixed `[reva_ai]`. Useful markers:

| Event | Marker |
|---|---|
| Inbound auth entered | `[reva_ai] authorize inbound HTTP:` |
| Inbound PDP decision | `[reva_ai] pdp_token_validation decision:` |
| Structured auth / PDP records | `[reva_ai] auth ::` / `[reva_ai] pdp ::` |
| Full PDP request/response (TRACE only) | `[reva_ai] TRACE pdp_token_validation request:` / `... response:` |
| Token rejected as expired | deny `reason=transaction_token_expired` (`code=token_expired`) |
| RTG disabled warning | `[reva_ai] WARNING: RTG_DISABLED is set` |

Set `REVA_AI_LOG_LEVEL=TRACE` to capture full PDP request/response
bodies (useful for debugging policy issues).

### 15.4 Final-turn recording (conversation correlation)

When you pass `conversation_key` (and `conversation_key_location`) to
`@reva_ai_authorise`, the decorator captures the agent's final response —
including the tail of a `StreamingResponse` — and posts it to RTG for
conversation-level audit correlation, keyed by the conversation id. This is
optional: leave `conversation_key` unset to skip it. Recording is also
skipped when the inbound call already carries an `X-Transaction-Token` (i.e.
an inner hop), so only the outermost turn of a chain is recorded.

---

## 16. Migration from raw `httpx`

If you have existing agent code making raw HTTP calls between services:

```diff
- import httpx
- async with httpx.AsyncClient() as client:
-     resp = await client.post(billing_url, json=body, headers=headers)
+ from reva_ai.sdk.ai.proxy import revaclient
+ resp = await revaclient.proxy.agent(
+     endpoint_url=billing_url,
+     method="POST",
+     body=body,
+     prompt_key="text",            # field carrying the prompt
+     resource_id="billing-agent",  # target's PDP id
+ )
```

The proxy returns an `httpx.Response`-shaped object — `.json()`,
`.raise_for_status()`, `.text`, `.status_code`, `.headers` all work
unchanged. Streaming behaves the same as `httpx.stream(...)`.

---

## 17. Common patterns

### 17.1 An agent that doesn't make outbound calls (leaf agent)

```python
@app.post("/v1/run")
@reva_ai_authorise(agent_name="leaf-agent", prompt_key="query")
async def run(body: dict, request: Request):
    # Just respond with LLM output. No proxy calls.
    return {"reply": llm.invoke(body["query"])}
```

### 17.2 An agent that fans out to several downstream agents

```python
@reva_ai_authorise(agent_name="orchestrator", prompt_key="query")
async def run(body: dict, request: Request):
    results = await asyncio.gather(
        revaclient.proxy.agent(endpoint_url="...", body={...}, resource_id="agent-a"),
        revaclient.proxy.agent(endpoint_url="...", body={...}, resource_id="agent-b"),
        revaclient.proxy.agent(endpoint_url="...", body={...}, resource_id="agent-c"),
    )
    ...
```

Each fan-out call gets its own PDP `/token/enrich`. If any denies, the
gather raises immediately — wrap with `return_exceptions=True` if you
want to continue past denies.

### 17.3 A streaming SSE agent

```python
@reva_ai_authorise(agent_name="streaming-agent", prompt_key="query")
async def stream(body: dict, request: Request):
    async with revaclient.proxy.agent(
        endpoint_url="http://downstream:9000/v1/stream",
        method="POST",
        stream=True,
        body=body,
        prompt_key="query",
        resource_id="downstream",
    ) as response:
        async for line in response.aiter_lines():
            yield line
```

### 17.4 An MCP server with multiple tools

```python
mcp = FastMCP("freight-tools")

@mcp.tool()
@reva_ai_authorise(tool_name="reva-rate-mcp",
                    action="invokeTool", prompt_key="origin_code")
def get_freight_quote(origin_code: str, destination_code: str):
    ...

@mcp.tool()
@reva_ai_authorise(tool_name="reva-rate-mcp",
                    action="invokeTool", prompt_key="tracking_number")
def get_shipment_status(tracking_number: str):
    ...
```

All tools on the same MCP server share `tool_name="reva-rate-mcp"` —
the **server** is the PDP entity, not the individual tool.

### 17.5 Calling a Reva-protected agent from a non-Reva client (test harness)

```python
import httpx

# Simulate a user request — just send the access token.
resp = httpx.post(
    "http://my-agent:9000/v1/run",
    headers={"Authorization": f"Bearer {access_token}"},
    json={"query": "Hello"},
)
```

No `rtg/a2a` block needed — the receiving agent's `@reva_ai_authorise`
constructs one from the access token + decorator config.

---

## 18. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `RevaAuthorizationError(reason="missing_credentials")` | No `Authorization` / `X-Transaction-Token` header | For first-hop, ensure the caller is sending a JWT. For workers, call `set_caller_identity()`. |
| 403 `endpoint resolution failed: entity lookup failed` | The URL isn't registered as an entity in the policy store, AND no `rtg/a2a.resource` fallback was provided | Either register the URL→entity mapping, or ensure the SDK is sending `resource_id` on outbound calls. |
| 403 `authorization denied by policy` | PDP found the entities but no policy permits the call | Add the right `permit (...)` to your policy store. |
| All requests succeed but no audit rows | Caller is using raw `httpx`, bypassing the proxy | Replace with `revaclient.proxy.agent` / `.mcp`. |
| MCP `tools/list` showing up in audit log | The MCP server's tool decorator was applied to a list handler by mistake | Decorate only `tools/call` handlers (the actual tool functions). |
| MCP call succeeds but no PDP check / no audit row | `proxy.mcp` was called without `endpoint_protected=True` (the default `False` invokes the tool directly) | Pass `endpoint_protected=True` to run the PDP-mediated MCP lifecycle. |
| `ValueError: agent_type must be one of: crew, langgraph` | Used `agent_type="MCP"` (the old, removed pattern) on a tool | Use `tool_name="<mcp-server-id>"` for MCP servers. `agent_type` is only for `crew`/`langgraph` HTTP agents. |
| `ValueError: Pass exactly one of agent_name … tool_name … crew_name` | Zero or multiple of these kwargs were passed | Pass exactly one: `agent_name` (HTTP), `tool_name` (MCP), or `crew_name` (CrewAI crew factory). |
| Token rejected with `transaction_token_expired` | Clock skew or slow downstream | Bump `REVA_AI_TOKEN_LEEWAY_SECONDS` to `10`, or fix the clock skew. |
| `PermissionError: RequestContext.set_X is an SDK-internal API` | User code is calling a context mutator | Use `set_caller_identity()` from `adapters` instead. |
| `WARNING: RTG_DISABLED is set` | The env is true in this pod | Remove from deployment manifest. Never set this in prod. |
| Inbound `rtg/a2a.subject` arrives as `null` even on chained call | Caller is sending the wire body but not setting `rtg/a2a.subject` | Confirm caller uses `revaclient.proxy.agent` (not a hand-rolled body). |
| `principal` field at root of body keeps getting overwritten | The customer's body had a field named `principal` and they assumed the SDK wraps it | The SDK does NOT mutate root fields. Re-check — the SDK only adds `rtg/a2a`. |

---

## 19. Coding standards

When integrating the SDK, follow these rules. Customer-side reviews will
expect them.

1. **Decorate at the route boundary.** `@reva_ai_authorise` goes on the
   public-facing FastAPI route (or MCP tool function). Don't try to gate
   internal helpers with the decorator — use the proxy when those
   helpers make HTTP calls instead.
2. **One `agent_name` per service.** All routes on the supervisor
   agent's FastAPI app use `agent_name="shipment-supervisor-agent"`. The
   agent is the unit of policy, not the route.
3. **One `agent_name` per MCP server.** All tools on the carrier MCP
   server use `agent_name="reva-carrier-mcp"`. Tool names are per-tool;
   the server name is shared.
4. **Always pass `prompt_key`.** Even on routes that don't have a
   user-visible prompt, pass the body field name your handler is
   reading — PDP uses it for IBAC drift scoring and audit context.
5. **Always pass `resource_id` on outbound.** It identifies the target
   to PDP. Without it, PDP falls back to URL-lookup against the entities
   table, which is fine but less explicit.
6. **Don't read `Authorization` directly in your handler.** The SDK
   already extracted and validated it. If you need the raw token
   downstream, use the proxy — it'll mint and forward a fresh
   transaction token.
7. **Don't catch and swallow `RevaAuthorizationError`** unless you're
   logging and re-raising. Denies should propagate.
8. **Don't import from `reva_ai.sdk.ai.utils.context`** in user code.
   That module is SDK-internal — its setters intentionally raise on
   external callers.

---

## 20. Quick reference card

```python
# Inbound (FastAPI agent)
@app.post("/v1/run")
@reva_ai_authorise(agent_name="my-agent", auth_key="Authorization", prompt_key="query")
async def run(body, request): ...

# Inbound (FastMCP tool)
@mcp.tool()
@reva_ai_authorise(tool_name="my-mcp", action="invokeTool", prompt_key="container_id")
def my_tool(...): ...

# Outbound (agent → agent)
resp = await revaclient.proxy.agent(
    endpoint_url=...,
    method="POST",
    body={...},
    prompt_key="text",
    resource_id="target-agent",
)

# Outbound (agent → MCP)
result = await revaclient.proxy.mcp(
    tool=mcp_tool,
    arguments={...},
    mcp_client="http://mcp:9101/mcp",
    resource_id="reva-target-mcp",
    endpoint_protected=True,
)

# Outbound (agent → arbitrary API)
async with revaclient.proxy.api(endpoint_url=..., method="GET") as r:
    return r.json()

# Non-FastAPI inbound (workers, A2A SDK)
from reva_ai.sdk.ai.adapters import set_caller_identity, authorise_inner_call_async

set_caller_identity(
    agent_name="my-agent", auth_token=token,
    inbound_rtg_a2a=<extracted from request body>,
)
await authorise_inner_call_async(resource_name="my-agent", action="invokeAgent")
```

---

## 21. Where to file issues / get help

- SDK source repository: ask your Reva representative for access.
- Sample integrations: see the `pm_demo` repos shared with your tenant
  (supplychain-langgraph + finance-langgraph cover the FastAPI, LangGraph,
  and MCP integration patterns end-to-end).
- Support: `support@reva.ai` for production issues, or your dedicated
  Reva account contact for integration questions.
