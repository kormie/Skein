defmodule Skein.SpecExamplesTest do
  @moduledoc """
  Verifies that all code examples in SKEIN_SPEC.md sections 8.1-8.5
  parse successfully. This ensures the spec stays aligned with the
  actual implementation.
  """
  use ExUnit.Case, async: true

  @section_8_examples [
    {"8.1 Hello World",
     """
     module Hello {
       fn greet(name: String) -> String {
         "Hello, ${name}!"
       }
     }
     """},
    {"8.2 HTTP API with Types",
     """
     module UserService {
       capability http.in
       capability store.table("users")
       capability uuid
       capability instant

       type User {
         id: Uuid @primary
         email: Email @unique
         name: String
         created_at: Instant
       }

       type CreateUserInput {
         email: Email
         name: String
       }

       handler http GET "/users/:id" (req) -> {
         let id = Uuid.parse(req.params.id)!
         let user = store.users.get(id)
         match user {
           Ok(u)           -> respond.json(200, u)
           Err(NotFound)   -> respond.json(404, { error: "not found" })
         }
       }

       handler http POST "/users" (req) -> {
         let data = req.json[CreateUserInput]()?
         let user = store.users.put({
           id: uuid.new(),
           email: data.email,
           name: data.name,
           created_at: instant.now()
         })!
         respond.json(201, user)
       }
     }
     """},
    {"8.3 Queue Worker",
     """
     module BillingWorker {
       capability queue.consume("billing.events")
       capability http.out("api.stripe.com")
       capability store.table("transactions")
       capability uuid
       capability instant

       enum BillingEvent {
         ChargeSucceeded(charge_id: String, amount: Int)
         DisputeCreated(dispute_id: String, charge_id: String)
       }

       handler queue "billing.events" (msg) -> {
         idempotent(msg.id)

         match msg.json[BillingEvent]()? {
           BillingEvent.ChargeSucceeded(charge_id, amount)   -> record_charge(charge_id, amount)
           BillingEvent.DisputeCreated(dispute_id, charge_id) -> handle_dispute(dispute_id, charge_id)
         }
       }

       fn record_charge(charge_id: String, amount: Int) -> Result[String, StoreError] {
         store.transactions.put({
           id: uuid.new(),
           charge_id: charge_id,
           amount: amount,
           created_at: instant.now()
         })
       }

       fn handle_dispute(dispute_id: String, charge_id: String) -> Result[String, HttpError] {
         let charge = http.get("https://api.stripe.com/v1/charges/${charge_id}")?
         trace.annotate("dispute_charge", charge.body)
         Ok("resolved")
       }
     }
     """},
    {"8.4 Agent with LLM and Tools (nested agent)",
     """
     module RefundService {
       capability model("anthropic", "claude-opus-4-8")
       capability tool.use(Stripe.CreateRefund)
       capability store.table("tickets")

       type RefundDecision {
         action: String @one_of(["approve", "deny"])
         amount: Int @min(0)
         reason: String
       }

       tool Stripe.CreateRefund {
         description: "Issue a refund via Stripe"

         input {
           customer_id: String @description("Stripe customer ID")
           amount: Int @description("Amount in cents") @min(1)
         }

         output {
           id: String
           amount: Int
           status: String
         }

         errors { StripeError }

         implement {
           let response = http.post("https://api.stripe.com/v1/refunds", {
             customer: customer_id,
             amount: amount
           })
           match response {
             Ok(r)  -> Ok({ id: r.body.id, amount: r.body.amount, status: r.body.status })
             Err(e) -> Err(StripeError.from(e))
           }
         }
       }

       supervisor Main {
         child HttpServer { restart: permanent }
         child AgentPool(RefundAgent) { max: 5000, restart: transient }
         strategy: one_for_one
         max_restarts: 10 per 60s
       }

       -- The refund agent: processes refund requests through multiple phases.
       -- Module-level capabilities (model, store.table) apply here too.
       agent RefundAgent {
         capability memory.kv("refund_sessions")

         state {
           ticket_id: String
           customer_id: String
         }

         enum Phase {
           Analyze  -> [Refund, Done, Failed]
           Refund   -> [Done, Failed]
           Failed   -> [Analyze]
           Done     -> []
         }

         on start(ticket_id: String, customer_id: String) -> {
           memory.put("ticket_id", ticket_id)
           memory.put("customer_id", customer_id)
           transition(Phase.Analyze)
         }

         on phase(Phase.Analyze) -> {
           let ticket_id = memory.get("ticket_id")!
           let ticket = store.tickets.get(ticket_id)!

           let decision = llm.json[RefundDecision](
             model: "claude-opus-4-8",
             system: "Decide if this ticket warrants a refund. Return JSON.",
             input: ticket
           )

           match decision {
             Ok(d) -> {
               memory.put("decision", d)
               match d.action {
                 "approve" -> transition(Phase.Refund)
                 "deny"    -> transition(Phase.Done)
               }
             }
             Err(e) -> {
               emit AnalysisError { ticket_id: ticket_id }
               transition(Phase.Failed)
             }
           }
         }

         on phase(Phase.Refund) -> {
           let d = memory.get("decision")!
           let customer_id = memory.get("customer_id")!
           let result = tool.call(Stripe.CreateRefund, {
             customer_id: customer_id,
             amount: d.amount
           })

           match result {
             Ok(refund) -> {
               let tid = memory.get("ticket_id")!
               emit RefundIssued { ticket_id: tid, refund_id: refund.id }
               transition(Phase.Done)
             }
             Err(e) -> {
               let tid = memory.get("ticket_id")!
               emit RefundFailed { ticket_id: tid }
               transition(Phase.Failed)
             }
           }
         }

         on phase(Phase.Failed) -> {
           suspend("Requires human review")
         }

         on phase(Phase.Done) -> {
           stop()
         }
       }
     }
     """},
    {"8.5 Tests",
     """
     module RefundService {
       fn eligible(amount: Int) -> Bool {
         amount <= 5000
       }

       fn greeting(name: String) -> String {
         "Hello, ${name}!"
       }

       test "greeting returns hello message" {
         let result = greeting("world")
         assert result == "Hello, world!"
       }

       test "small refunds are eligible" {
         assert eligible(2500) == true
         assert eligible(9900) == false
       }

       scenario "high-value refund requires manual review" {
         given {
           ticket_id: "abc-123"
         }

         expect {
           -- `given` bindings are in scope in the expect block.
           assert ticket_id == "abc-123"
         }
       }
     }
     """}
  ]

  for {name, source} <- @section_8_examples do
    @tag :spec_example
    test "spec example: #{name} compiles with zero diagnostics" do
      source = unquote(source)
      path = Path.join(System.tmp_dir!(), "spec_example_#{:erlang.phash2(unquote(name))}.skein")
      File.write!(path, source)
      on_exit(fn -> File.rm(path) end)

      case Skein.Compiler.check_file(path) do
        {:ok, %{errors: [], warnings: []}} ->
          :ok

        {:ok, %{errors: errors, warnings: warnings}} ->
          flunk(
            "Spec example has diagnostics:\n" <>
              Enum.map_join(errors ++ warnings, "\n", fn e ->
                "  [#{e.code}] L#{e.location.line}: #{e.message}"
              end)
          )

        {:error, message} ->
          flunk(message)
      end
    end
  end
end
