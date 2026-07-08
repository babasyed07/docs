// Sample agentic authorization policies for Reva AI Workload Security.
// These are starting points — adapt entity ids, actions, attributes, and
// conditions to your own schema and topology, then validate them in Policy
// Testing before publishing.

// 1) A user may invoke the supervisor agent.
permit (
    principal == User::"john",
    action    == Action::"invokeAgent",
    resource  == Agent::"shipment-supervisor-agent"
);

// 2) Agent-to-agent: the supervisor may delegate to the billing agent.
permit (
    principal == Agent::"shipment-supervisor-agent",
    action    == Action::"invokeAgent",
    resource  == Agent::"billing-agent"
);

// 3) Agent-to-tool: the compliance agent may invoke its MCP server.
permit (
    principal == Agent::"compliance-agent",
    action    == Action::"invokeTool",
    resource  == MCP::"reva-compliance-mcp"
);

// 4) Context-based: allow a tool call only for a specific container id
//    that the agent passes at runtime.
permit (
    principal,
    action   == Action::"invokeTool",
    resource == MCP::"reva-rate-mcp"
)
when { context.container_id == "MSCU4429881" };

// 5) On-behalf-of: allow an agent to act only when it is operating on
//    behalf of a low-risk user.
permit (
    principal,
    action == Action::"invokeAgent",
    resource
)
when { context.onBehalfOf.riskTier == "LOW" };

// 6) Intent-based: allow a tool call only when its intent is one the
//    caller is permitted to make.
permit (
    principal,
    action == Action::"invokeTool",
    resource
)
when { context.intent in principal.allowedIntents };

// 7) Guardrail: forbid tool calls on behalf of a suspended user,
//    regardless of any permit above (forbid always wins in Cedar).
forbid (
    principal,
    action == Action::"invokeTool",
    resource
)
when { context.onBehalfOf.suspended == true };
