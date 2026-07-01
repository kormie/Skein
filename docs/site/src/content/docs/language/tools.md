---
title: Tools
description: How to declare and call tools in Skein for LLM function-calling and external integrations.
---

## Overview

Tools are Skein's mechanism for **LLM function calling** and structured external integrations. A tool declaration defines a contract (input schema, output schema) and an implementation. At compile time, the compiler generates JSON Schema manifests that LLM providers can use for function-calling.

## Declaring Tools

Tools are declared inside modules with the `tool` keyword:

```skein
module PaymentService {
  tool CreateRefund {
    description: "Issue a refund via the payment provider"

    input {
      customer_id: String @description("Stripe customer ID")
      amount: Int @min(1) @max(100000)
    }

    output {
      id: String
      status: String
    }

    errors { RefundError }

    implement {
      match http.post("https://api.stripe.com/v1/refunds", customer_id) {
        Ok(r) -> Ok({ id: r.body.id, status: r.body.status })
        Err(e) -> Err(RefundError.from(e))
      }
    }
  }
}
```

### Syntax

```
tool <Name> {
  description: "<text>"      -- optional

  input {                    -- required: input fields
    <field>: <Type> [annotations]
  }

  output {                   -- required: output fields
    <field>: <Type>
  }

  errors { <Error>, ... }   -- optional: error types

  implement {               -- required: implementation body
    <expressions>
  }
}
```

The `implement` body must evaluate to `Result[output, error]` — the runtime
invokes it and matches on `Ok`/`Err`, so a bare value is a compile error
(`E0020`). `Ok({ ... })` payloads are checked field-by-field against the
declared `output { ... }` shape.

### Dotted Names

Tool names can use dots for namespacing:

```skein
tool Stripe.CreateRefund { ... }
tool Stripe.GetBalance { ... }
```

## JSON Schema Generation

The compiler automatically generates JSON Schema from tool input and output fields. This is available at runtime via the `__tools__/0` metadata function.

Given:

```skein
tool CreateRefund {
  input {
    customer_id: String @description("Stripe customer ID")
    amount: Int @min(1) @max(100000)
  }
  output { id: String, status: String }
  implement { Ok({ id: "r1", status: "ok" }) }
}
```

The generated `input_schema` is:

```json
{
  "type": "object",
  "properties": {
    "customer_id": { "type": "string", "description": "Stripe customer ID" },
    "amount": { "type": "integer", "minimum": 1, "maximum": 100000 }
  },
  "required": ["amount", "customer_id"]
}
```

Constraint annotations (`@min`, `@max`, `@description`, `@one_of`, `@default`) are included in the schema. `Option[T]` fields are excluded from `required`.

## Tool Metadata

Every compiled module with tools exports `__tools__/0`:

```elixir
mod.__tools__()
#=> [%{
#     name: "CreateRefund",
#     description: "Issue a refund via the payment provider",
#     input: [%{name: "customer_id", type: "String"}, %{name: "amount", type: "Int"}],
#     input_schema: %{"type" => "object", "properties" => %{...}, "required" => [...]},
#     output: [%{name: "id", type: "String"}, %{name: "status", type: "String"}],
#     output_schema: %{"type" => "object", "properties" => %{...}, "required" => [...]},
#     impl: :__tool_impl_0__
#   }]
```

The `input_schema` and `output_schema` fields are proper JSON Schema objects suitable for passing directly to LLM function-calling APIs. `impl` names the compiled entry point for the tool's `implement` block.

## How Tools Are Registered

Tools are the one cross-module seam in Skein: a `tool.call` in one module
resolves to a `tool` declaration in another through the runtime tool
registry. When `skein build`, `skein test`, or `skein run` loads a compiled
module, every tool it declares is registered automatically — the declared
schemas are kept for input validation and the `implement` block becomes the
tool's executable body. Registration is idempotent: reloading a module
overwrites its previous entries.

From Elixir, the same wiring is available directly:

```elixir
Skein.Runtime.Tool.register_module(mod)
```

## Calling Tools

### From Skein Code

Use the `tool.*` effect calls to interact with tools at runtime:

```skein
module AgentService {
  capability tool.use(CreateRefund)

  fn process_refund(args: String) -> String {
    let result = tool.call(CreateRefund, args)
    result
  }

  fn list_available() -> String {
    tool.list()
  }

  fn get_schema() -> String {
    tool.schema(CreateRefund)
  }
}
```

| Effect | Description | Returns |
|--------|-------------|---------|
| `tool.call(ToolName, args)` | Execute a registered tool | `Result[Map, ToolError]` |
| `tool.list()` | List all registered tools | `Result[List[ToolInfo], ToolError]` |
| `tool.schema(ToolName)` | Get a tool's schema | `Result[Map, ToolError]` |

### Capability Required

Tool calls require a `capability tool.use(ToolName)` declaration. Without it, the analyzer produces error E0012.

### Tracing

Every `tool.call` is automatically traced with:
- `kind: :tool`
- `method: :call`
- `name: "ToolName"`
- `duration_us` and `outcome`
