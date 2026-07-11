---
title: Agent composition
description: Tools as agent boundaries for composing Skein modules and agents.
---

## Tools are agent boundaries

For 1.0, Skein's official agent-composition model is: **compose modules and agents through tools, not direct function calls**. A module that wants to be used by another agent publishes a `tool`; the consuming module or agent declares `capability tool.use(...)`; the call crosses the boundary with `tool.call(...)`.

That gives every boundary a typed contract, a JSON Schema, a capability grant, runtime validation, and an automatic trace span. Plain `fn` declarations remain module-private from Skein code. `Billing.calculate(...)` is not the composition model; `tool.call(Billing.Calculate, {...})` is.

## Provider module: expose a tool

The provider owns its implementation details and exposes only the tool contract:

```text
module Fraud {
  capability model("anthropic", "claude-opus-4-8")

  tool Fraud.Score {
    description: "Score a signup for fraud risk."

    input {
      email: String @description("Customer email address")
      amount: Int @min(1)
    }

    output {
      decision: String @one_of(["approve", "review", "deny"])
      reason: String
    }

    implement {
      let verdict = llm.chat(
        "claude-opus-4-8",
        "Return approve, review, or deny for this signup.",
        email
      )!
      Ok({ decision: verdict, reason: "model policy" })
    }
  }
}
```

The input and output blocks are the API. The implementation may call `llm.chat`, HTTP, storage, queues, or helper functions, but callers only see `Fraud.Score`.

## Consumer module: declare the grant and call the tool

The consumer declares exactly which external tool it is allowed to use:

```text
module Onboarding {
  agent SignupAgent {
    capability tool.use(Fraud.Score)

    enum Phase {
      Score -> [Approved, Review]
      Approved -> []
      Review -> []
    }

    on start(email: String) -> {
      transition(Phase.Score)
    }

    on phase(Phase.Score) -> {
      let score = tool.call(Fraud.Score, { email: "ada@example.com", amount: 4999 })!
      match score.decision {
        "approve" -> transition(Phase.Approved)
        _ -> transition(Phase.Review)
      }
    }

    on phase(Phase.Approved) -> { stop() }
    on phase(Phase.Review) -> { suspend("Manual review") }
  }
}
```

The analyzer rejects `Fraud.score(...)` or any other qualified cross-module function call. If the capability is missing, `tool.call(Fraud.Score, ...)` is also rejected.

## Scenario tests mock the tool's inner capabilities

A scenario can provide test-only implementations for the effects used inside a tool. The test still calls the public tool, so it exercises the same boundary production code uses while replacing the tool's inner capability environment:

```skein
module SignupScenarios {
  capability tool.use(Fraud.Score)
  capability model("anthropic", "claude-opus-4-8")

  tool Fraud.Score {
    input {
      email: String
      amount: Int
    }
    output {
      decision: String
      reason: String
    }
    implement {
      let decision = llm.chat("claude-opus-4-8", "Score this signup", email)!
      Ok({ decision: decision, reason: "scenario-controlled" })
    }
  }

  scenario "approved signup" {
    capability tool.use(Fraud.Score) {
      capability model("anthropic", "claude-opus-4-8") {
        implement(req: LlmRequest) -> Result[LlmResponse, LlmError] {
          Ok(LlmResponse { content: "approve", model: "claude-opus-4-8", usage: {} })
        }
      }
    }

    expect {
      let result = tool.call(Fraud.Score, { email: "ada@example.com", amount: 4999 })!
      assert result.decision == "approve"
    }
  }
}
```

The scenario's `capability tool.use(Fraud.Score) { ... }` block creates an envelope for that tool call. The nested `model(...)` provider is visible while the tool body runs, then disappears after the scenario finishes. Production tool registration is unchanged.

## Tool schemas are LLM manifests and API contracts

Every compiled module with tools exposes `__tools__/0` metadata. The same generated schemas serve three roles:

- **LLM tool manifests:** `input_schema` is passed to model providers as the function/tool parameter schema, with descriptions and constraints preserved.
- **Runtime validation:** `tool.call` validates the caller's payload and the tool's output against the contract.
- **Service API contracts:** hosts can publish the same schema as an HTTP, queue, or RPC contract without rewriting the type definition.

For example, a `tool Fraud.Score` contract generates metadata equivalent to:

```json
{
  "name": "Fraud.Score",
  "description": "Score a signup for fraud risk.",
  "input_schema": {
    "type": "object",
    "properties": {
      "email": { "type": "string", "description": "Customer email address" },
      "amount": { "type": "integer", "minimum": 1 }
    },
    "required": ["amount", "email"]
  },
  "output_schema": {
    "type": "object",
    "properties": {
      "decision": { "type": "string", "enum": ["approve", "review", "deny"] },
      "reason": { "type": "string" }
    },
    "required": ["decision", "reason"]
  }
}
```

This is why tools are the only cross-module seam: one declaration becomes the model-facing manifest, the runtime guardrail, the test seam, and the human-readable API.

## Conformance rule

Skein conformance requires user modules to compose through tools. Direct qualified calls across modules are invalid even if the target function exists on the generated BEAM module for Elixir interop. Use a local helper for code inside the same module; use a tool for code outside it.
