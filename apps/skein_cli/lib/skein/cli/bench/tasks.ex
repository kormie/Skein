defmodule Skein.CLI.Bench.Tasks do
  @moduledoc """
  The fixed task suite for the agent-writability benchmark (#320).

  Each task asks a code-generating agent for a small, complete Skein
  program exercising one slice of the language surface: pure functions,
  records with `Option`, `Result` flows, enums and `match`, stdlib
  callbacks, string interpolation, tools, HTTP handlers, the typed store,
  agents, LLM effects, and scenario capability environments.

  Tasks pin their module names so recordings and reports stay stable
  across runs. The optional `context` supplements the agent primer with
  the effect signatures a task needs — the primer is deliberately compact,
  and the benchmark measures diagnostic-loop convergence, not recall of
  surface the provided context never mentioned.
  """

  @type task :: %{
          id: String.t(),
          name: String.t(),
          prompt: String.t(),
          context: String.t() | nil
        }

  @doc "The fixed benchmark suite, in a stable order."
  @spec suite() :: [task()]
  def suite do
    [
      %{
        id: "pure_fns",
        name: "Pure functions and unit tests",
        prompt: """
        Write a Skein module named `TempMath` with:
        - `fn celsius_to_fahrenheit(c: Float) -> Float` — multiply by 9.0, divide by 5.0, add 32.0.
        - `fn clamp(n: Int, low: Int, high: Int) -> Int` — n bounded to the inclusive range [low, high].
        - a `test` for each function.
        """,
        context: nil
      },
      %{
        id: "records_option",
        name: "Records with Option fields",
        prompt: """
        Write a Skein module named `Contacts` with:
        - `type Contact { id: Uuid @primary, name: String, nickname: Option[String] }`
        - `fn display_name(c: Contact) -> String` — the nickname when present, otherwise the name.
        - a `test` that constructs a Contact with a nickname and asserts `display_name`
          returns the nickname, and a second Contact without one asserting it returns
          the name. Use `Uuid.parse("00000000-0000-4000-8000-000000000001")!` for ids.
        """,
        context: nil
      },
      %{
        id: "result_flow",
        name: "Result propagation and matching",
        prompt: """
        Write a Skein module named `Numbers` with:
        - `fn parse_and_double(s: String) -> Result[Int, String]` — parse with
          `Int.parse(s)` (returns `Result[Int, String]`), propagate a parse failure
          to the caller, and double the parsed value.
        - `fn sum_or_zero(a: String, b: String) -> Int` — the sum of both parsed
          values, or 0 when either fails to parse.
        - a `test` covering a success and a failure path for each function.
        """,
        context: nil
      },
      %{
        id: "enums_match",
        name: "Enums and exhaustive match",
        prompt: """
        Write a Skein module named `Orders` with:
        - `enum Status { Pending Paid Shipped Cancelled }`
        - `fn label(s: Status) -> String` — a human-readable label per variant,
          matched exhaustively.
        - `fn is_open(s: Status) -> Bool` — true for Pending and Paid, false otherwise.
        - a `test` for each function.
        """,
        context: nil
      },
      %{
        id: "list_callbacks",
        name: "Stdlib list pipeline with callbacks",
        prompt: """
        Write a Skein module named `Scores` with:
        - `fn add_bonus(score: Int) -> Int` — adds 5.
        - `fn is_passing(score: Int) -> Bool` — true when the score is at least 60.
        - `fn curved_passing(scores: List[Int]) -> List[Int]` — applies the bonus to
          every score and keeps only passing ones, using `List.map`/`List.filter`
          with `&fn` callbacks and the pipe operator.
        - a `test` asserting `curved_passing([55, 90, 20]) == [60, 95]`.
        """,
        context: nil
      },
      %{
        id: "string_interp",
        name: "String interpolation",
        prompt: """
        Write a Skein module named `Greeter` with:
        - `type User { id: Uuid @primary, name: String, city: String }`
        - `fn welcome(name: String, city: String) -> String` — "Welcome, <name> of <city>!"
          built with string interpolation.
        - `fn describe(u: User) -> String` — "<name> lives in <city>." interpolating
          the record's fields.
        - a `test` for `welcome`.
        """,
        context: nil
      },
      %{
        id: "tool_decl",
        name: "Tool declaration and call",
        prompt: """
        Write a Skein module named `Billing` with:
        - a tool `Billing.ComputeTax`: input `{ amount: Int, rate_pct: Int }`, output
          `{ tax: Int }`, whose implementation computes `amount * rate_pct / 100`.
        - the capability needed to call it, and `fn tax_due(amount: Int) -> Int` that
          calls the tool with a 10 percent rate and returns the tax (crash on error).
        """,
        context: """
        Tool implementations see their input fields directly in scope (`amount`, not
        `input.amount`) and must return the output shape wrapped in `Ok(...)`, e.g.
        `implement { Ok({ tax: ... }) }`. `tool.call(Billing.ComputeTax, { amount: a,
        rate_pct: 10 })` returns `Result[Map, ToolError]`; field-access the unwrapped
        map for output fields.
        """
      },
      %{
        id: "http_handlers",
        name: "HTTP handlers",
        prompt: """
        Write a Skein module named `Ping` with:
        - the capability for inbound HTTP.
        - `handler http GET "/ping/:name"` responding 200 JSON `{ message: "pong <name>" }`
          using the path parameter.
        - `type EchoBody { text: String }` and `handler http POST "/echo"` that decodes
          the request body as EchoBody and responds 200 JSON `{ echoed: <text> }`.
        """,
        context: """
        `req.params.<name>` reads a path parameter (a String). `req.json[T]()` decodes
        the request body, returning a Result. `respond.json(status, value)` sends a
        JSON response. Interpolation only accepts identifiers and field access — bind
        anything else with `let` first.
        """
      },
      %{
        id: "typed_store",
        name: "Typed store tables",
        prompt: """
        Write a Skein module named `Inventory` with:
        - `type Item { sku: String @primary, qty: Int }`
        - the typed store capability for an "items" table of Item.
        - `fn restock(sku: String, qty: Int) -> Result[Item, StoreError]` storing an Item.
        - `fn lookup_qty(sku: String) -> Int` — the stored quantity, or 0 when the item
          is not found.
        """,
        context: """
        `capability store.table("items", Item)` grants `store.items.get/put/delete/query`,
        typed against Item: `store.items.get(sku)` and `store.items.put(item)` both return
        `Result[Item, StoreError]`. Not-found matches as `Err(StoreError.NotFound)`.
        """
      },
      %{
        id: "agent_lifecycle",
        name: "Agent phases and transitions",
        prompt: """
        Write a top-level Skein agent named `Countdown`:
        - a memory.kv capability (namespace "countdown").
        - a Phase enum: Ready -> [Ticking], Ticking -> [Done], Done -> [].
        - `on start(n: Int)` stores n in memory under "remaining" and transitions to Ready.
        - `on phase(Ready)` transitions to Ticking.
        - `on phase(Ticking)` reads the remaining value and transitions to Done.
        - `on phase(Done)` stops the agent.
        """,
        context: nil
      },
      %{
        id: "llm_effect",
        name: "Typed LLM JSON output",
        prompt: """
        Write a Skein module named `Poet` with:
        - the model capability for provider "anthropic", model "claude-opus-4-8".
        - `type PoemCheck { ok: Bool, reason: String }`.
        - `fn validate(topic: String) -> Result[PoemCheck, LlmError]` — asks the model
          via `llm.json[PoemCheck]` to return typed JSON deciding whether the topic is
          suitable for a haiku, propagating model or schema errors to the caller.
        - `fn is_valid_topic(topic: String) -> Result[Bool, LlmError]` — calls
          `validate`, propagates errors, and returns the typed `ok` field.
        """,
        context: """
        `llm.json[T](model: String, system: String, input: U) -> Result[T, LlmError]`
        requires `capability model(provider, model_name)`. The compiler derives the JSON
        schema from `T`; field access on the unwrapped result is typed.
        """
      },
      %{
        id: "scenario_providers",
        name: "Scenario capability environments",
        prompt: """
        Write a Skein module named `Triage` with:
        - the model capability (provider "anthropic", model "claude-opus-4-8").
        - a tool `Triage.Classify`: input `{ text: String }`, output `{ label: String }`,
          implemented by asking the model via `llm.chat` to classify the text into
          exactly one word.
        - a `scenario` "classify works offline" that calls the tool with a stubbed model
          provider returning "billing" and asserts the tool's label is "billing".
        """,
        context: """
        A scenario declares the complete capability environment a tool may exercise:

            scenario "name" {
              capability tool.use(Mod.Tool) {
                capability model("anthropic", "claude-opus-4-8") {
                  implement(req: LlmRequest) -> Result[LlmResponse, LlmError] {
                    Ok(LlmResponse { text: "..." })
                  }
                }
              }
              expect {
                let result = tool.call(Mod.Tool, { text: "..." })!
                assert result.label == "..."
              }
            }

        `type LlmRequest { model: String, system: String, prompt: String }` and
        `type LlmResponse { text: String }` are built in. Provider bodies must be pure.
        The envelope must cover every effect the tool reaches.
        """
      }
    ]
  end
end
