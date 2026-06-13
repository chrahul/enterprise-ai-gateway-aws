# Agentic AI

## What Is an AI Agent

An AI agent is a system in which a language model does not just generate a single response — it reasons through a goal, selects and invokes tools, observes results, and iterates until the task is complete. Agents extend LLMs from a one-shot query-response pattern to a multi-step, goal-directed reasoning loop.

The core components of an agent:

| Component | Role |
|---|---|
| **LLM** | Reasons about the goal, selects the next action |
| **Tools** | Functions the LLM can call (APIs, databases, code interpreters) |
| **Memory** | Stores conversation history and intermediate results |
| **Planning** | Decomposes a goal into a sequence of steps |
| **Observation** | Reads tool outputs and updates the plan accordingly |

## The ReAct Loop

Most production agents use a Reasoning + Acting (ReAct) pattern:

```
Goal
 │
 ▼
Thought: What do I need to do to achieve this goal?
 │
 ▼
Action: Call tool X with parameters Y
 │
 ▼
Observation: Tool returned Z
 │
 ▼
Thought: Given Z, what is the next step?
 │
 └── Repeat until done
 │
 ▼
Final Answer
```

The LLM generates a "thought" explaining its reasoning, selects an action (tool call), receives the observation, and continues until it has enough information to produce a final response.

## Tools and Function Calling

Tools are ordinary functions or API calls that an agent can invoke. The LLM is provided with a schema describing available tools and their parameters. Claude 3.5 Sonnet and Claude 3 Haiku both support function calling via the standard OpenAI function calling format.

Example tool definitions:

```json
[
  {
    "name": "search_knowledge_base",
    "description": "Search the internal knowledge base for policy documents",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {"type": "string", "description": "The search query"}
      },
      "required": ["query"]
    }
  },
  {
    "name": "create_ticket",
    "description": "Create a support ticket in the issue tracker",
    "parameters": {
      "type": "object",
      "properties": {
        "title": {"type": "string"},
        "description": {"type": "string"},
        "priority": {"type": "string", "enum": ["low", "medium", "high"]}
      },
      "required": ["title", "description", "priority"]
    }
  }
]
```

All tool call requests flow through the AI Gateway. The gateway records the token usage for both the tool selection prompt and the follow-up synthesis request.

## Model Context Protocol (MCP)

The Model Context Protocol (MCP) is an open standard for connecting AI agents to external data sources and tools. It defines a structured way for:

- Hosts (AI applications) to discover available resources and tools
- Servers (MCP providers) to expose capabilities without custom integration work
- Agents to call tools in a provider-agnostic way

MCP simplifies the tool ecosystem: instead of each agent integrating directly with each data source, agents speak MCP and data sources expose MCP servers.

```
Agent ──▶ MCP Client ──▶ MCP Protocol ──▶ MCP Server ──▶ Data Source / API
```

LiteLLM supports MCP tool call routing. Agents built on Claude can use MCP servers for:
- Internal documentation (Confluence MCP server)
- Databases (PostgreSQL MCP server)
- Issue trackers (Jira MCP server)
- Code repositories (GitHub MCP server)

MCP is a roadmap item for this gateway. See [99-roadmap.md](99-roadmap.md).

## Multi-Agent Systems

Complex enterprise tasks require specialisation. Multi-agent systems use an **orchestrator agent** that decomposes a goal and delegates to **specialist agents**:

```
User Request
     │
     ▼
Orchestrator Agent
     │
     ├── Research Agent ──▶ AI Gateway ──▶ Bedrock Claude (+ RAG tools)
     ├── Analysis Agent ──▶ AI Gateway ──▶ Bedrock Claude (+ code interpreter)
     └── Writer Agent   ──▶ AI Gateway ──▶ Bedrock Claude (+ document template tools)
     │
     ▼
Composed Response to User
```

Every agent in the system uses the AI Gateway as its model access layer. The gateway provides:
- **Unified authentication** — Each agent uses an API key scoped to its function
- **Per-agent token budgets** — Prevent runaway costs if an agent enters an infinite loop
- **Audit trail** — Every agent tool call is recorded with its token usage
- **Rate limiting** — Prevents a single agent from saturating the Bedrock endpoint

## Human-in-the-Loop

Agentic workflows should not be fully autonomous for high-stakes actions (financial transactions, data deletion, privileged access grants). Human-in-the-loop (HITL) checkpoints pause the agent and request confirmation before proceeding.

HITL patterns:
- **Approval gate** — Agent proposes an action; a human approves via a UI or Slack message before the action is executed
- **Confidence threshold** — Agent executes actions above a confidence threshold automatically; routes low-confidence actions to a human queue
- **Review and edit** — Agent produces a draft (email, PR, document); a human reviews before the agent submits

## Enterprise Orchestration Frameworks

Several frameworks implement the patterns above at production scale:

| Framework | Notes |
|---|---|
| **LangChain / LangGraph** | Python-native; large tool ecosystem; LangGraph adds stateful multi-step workflows |
| **AutoGen (Microsoft)** | Multi-agent conversation framework; strong for code generation agents |
| **CrewAI** | Role-based multi-agent with sequential and parallel task pipelines |
| **Amazon Bedrock Agents** | Native AWS managed agent service; integrates with Bedrock Knowledge Bases |
| **Semantic Kernel (Microsoft)** | Enterprise-grade SDK for .NET and Python; strong Azure/M365 integration |

All of these frameworks can be configured to call the AI Gateway (`http://ai-gateway/v1/chat/completions`) rather than calling Bedrock or OpenAI directly. This is the recommended approach in this architecture because it preserves central governance.

## Relationship to the AI Gateway

Agents are consumers of the AI Gateway, not a replacement for it. The agent framework manages reasoning and tool orchestration; the gateway manages access, authentication, routing, and cost control.

```
Agent Framework Layer                  AI Gateway Layer
──────────────────────────────────     ──────────────────────────────────
│ Goal decomposition                │  │ Authentication (API key)         │
│ Tool selection (ReAct loop)       │  │ Model routing (alias → provider) │
│ Memory management                 │  │ Rate limiting                    │
│ Human-in-the-loop gates           │  │ Token budget enforcement         │
│ Multi-agent coordination          │  │ Observability (token, latency)   │
└───────────────────────────────────┘  └──────────────────────────────────┘
         │                                          ▲
         └──────────────────────────────────────────┘
              All model calls go through the gateway
```

## Security Considerations for Agentic Systems

Agents introduce new attack surfaces that do not exist in single-turn LLM applications:

- **Prompt injection** — A malicious tool result (web page, document, email) attempts to hijack the agent's instructions. Mitigate with strict tool output sanitisation and system prompt hardening.
- **Privilege escalation** — An agent with access to many tools can combine low-privilege actions to achieve a high-privilege effect. Use least-privilege tool scoping: each agent should have only the tools it needs.
- **Runaway loops** — A malfunctioning agent can call tools indefinitely. Enforce a maximum step count and per-key token budgets in the gateway to prevent runaway spend.
- **Data exfiltration** — An agent with access to internal data and external communication tools (email, HTTP) could exfiltrate sensitive information. Audit all outbound tool calls.

## See Also

- [13-rag-architecture.md](13-rag-architecture.md) — RAG as a tool for agents
- [10-multi-model-routing.md](10-multi-model-routing.md) — Routing different agent types to appropriate models
- [12-cost-governance.md](12-cost-governance.md) — Per-agent token budget controls
- [11-observability.md](11-observability.md) — Tracing multi-step agent workflows
- [99-roadmap.md](99-roadmap.md) — MCP integration and Bedrock Agents on the roadmap
