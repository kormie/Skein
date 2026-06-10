# Skein LLM Demo
# ===============
# Demonstrates Skein making real LLM calls via the Anthropic backend.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-ant-... mise exec -- mix run examples/demo.exs
#
# Requires a valid Anthropic API key in the environment.

alias Skein.Runtime.Llm
alias Skein.Runtime.Llm.AnthropicBackend

IO.puts("""
╔══════════════════════════════════════════╗
║       Skein LLM Demo                     ║
╚══════════════════════════════════════════╝
""")

# 1. Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

unless api_key do
  IO.puts("""
  ❌ ANTHROPIC_API_KEY not set!

  Run with:
    ANTHROPIC_API_KEY=sk-ant-... mise exec -- mix run examples/demo.exs
  """)

  System.halt(1)
end

IO.puts("✅ API key found (#{String.slice(api_key, 0..7)}...)")

# 2. Set the Anthropic backend
Llm.set_backend(AnthropicBackend)
IO.puts("✅ Anthropic backend configured\n")

# 3. Compile a Skein module with LLM capability
IO.puts("📝 Compiling Skein module with LLM capability...")

{:module, mod} =
  Skein.Compiler.compile_string("""
  module Demo {
    capability model("anthropic", "claude-opus-4-8")

    fn greet(name: String) -> String {
      llm.chat("claude-opus-4-8", "You are a friendly greeter. Respond in exactly one sentence.", name)
    }

    fn classify(text: String) -> String {
      llm.chat("claude-opus-4-8", "Classify the sentiment of this text as positive, negative, or neutral. Respond with just the word.", text)
    }
  }
  """)

IO.puts("✅ Compiled module: #{inspect(mod)}\n")

# 4. Make real LLM calls
IO.puts("🤖 Calling llm.chat via Skein...")
IO.puts("─────────────────────────────────────")

IO.puts("\n📞 mod.greet(\"World\")")
case mod.greet("World") do
  {:ok, response} ->
    IO.puts("   → #{response}")

  {:error, error} ->
    IO.puts("   ❌ Error: #{inspect(error)}")
end

IO.puts("\n📞 mod.classify(\"I love this new programming language!\")")
case mod.classify("I love this new programming language!") do
  {:ok, response} ->
    IO.puts("   → #{response}")

  {:error, error} ->
    IO.puts("   ❌ Error: #{inspect(error)}")
end

# 5. Show trace output
IO.puts("\n─────────────────────────────────────")
IO.puts("📊 Trace spans:")

case Skein.Runtime.Trace.recent_spans(10) do
  spans when is_list(spans) and length(spans) > 0 ->
    Enum.each(spans, fn span ->
      duration_s =
        if span[:duration_us],
          do: :erlang.float_to_binary(span[:duration_us] / 1_000_000, decimals: 1),
          else: "?"

      outcome_icon = if span[:outcome] == :ok, do: "✅", else: "❌"

      IO.puts(
        "   • #{span[:kind]}:#{span[:method]} #{span[:model]} (#{duration_s}s) #{outcome_icon}"
      )

      if span[:system], do: IO.puts("     system: #{inspect(span[:system])}")
      if span[:input], do: IO.puts("     input:  #{inspect(span[:input])}")
      if span[:output], do: IO.puts("     output: #{inspect(span[:output])}")

      if span[:usage] do
        IO.puts(
          "     tokens: #{span[:usage][:input_tokens]} in → #{span[:usage][:output_tokens]} out"
        )
      end
    end)

  _ ->
    IO.puts("   (trace collection may not be enabled in script mode)")
end

IO.puts("""

✨ Demo complete!

What happened:
  1. Set the Anthropic backend for real LLM calls
  2. Compiled a Skein module with model capability
  3. Called greet() and classify() — both made real API calls to Claude
  4. The Skein runtime checked capabilities, called the backend, and returned results

This is Skein: a language where AI calls are first-class, type-checked, capability-gated operations.
""")
