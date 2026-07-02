defmodule Skein.Runtime.Llm.ProviderBackend do
  @moduledoc """
  LLM backend that serves responses from a scenario `implement` provider on the
  active capability stack (#282).

  When a `model` provider is installed (the `capability model(...) { implement(req:
  LlmRequest) -> Result[LlmResponse, LlmError] { ... } }` block in a scenario
  envelope), `Skein.Runtime.Llm` resolves through this backend instead of replay
  or a live provider. The provider receives an `LlmRequest` (`%{model, system,
  prompt}`) and returns `Result[LlmResponse, LlmError]`; `LlmResponse.text`
  carries the completion, which `llm.json[T]` then decodes against the target
  schema exactly as a live response would be.

  `llm.embed` has no `implement` provider — `LlmResponse` is text-only — so
  `Skein.Runtime.Llm.embed/3` never resolves to this backend (#279): it
  resolves past the provider (replay → configured backend under the live
  policy). The `embed/2` callback below is defensive only.
  """

  @behaviour Skein.Runtime.Llm.Backend

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.Llm.Error

  @impl true
  def chat(model, system, input), do: provide(model, system, input)

  @impl true
  def json(model, system, input, _schema), do: provide(model, system, input)

  @impl true
  def stream(model, system, input) do
    case provide(model, system, input) do
      {:ok, text} when is_binary(text) -> {:ok, [text]}
      other -> other
    end
  end

  @impl true
  def embed(_model, _input) do
    {:error,
     Error.provider_error(
       "implement",
       "llm.embed has no implement provider (LlmResponse is text-only)"
     )}
  end

  defp provide(model, system, input) do
    case CapabilityStack.resolve("model") do
      {:implement, provider} ->
        request = %{model: model, system: system, prompt: to_prompt(input)}

        case provider.(request) do
          {:ok, %{text: text}} -> {:ok, text}
          {:ok, text} when is_binary(text) -> {:ok, text}
          {:error, _} = error -> error
          other -> {:ok, other}
        end

      :no_provider ->
        {:error, Error.provider_error("implement", "no model provider on the capability stack")}
    end
  end

  defp to_prompt(input) when is_binary(input), do: input

  defp to_prompt(input) do
    case Jason.encode(input) do
      {:ok, json} -> json
      _ -> inspect(input)
    end
  end
end
