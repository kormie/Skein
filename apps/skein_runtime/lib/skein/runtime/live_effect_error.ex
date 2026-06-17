defmodule Skein.Runtime.LiveEffectError do
  @moduledoc """
  Raised when a scenario or golden test tries to perform a live outbound effect
  (`http.out`, `model`) that the test-runner policy blocks (#283, Wave 3).

  Blocking is a test-harness policy decision, not a domain error, so it is raised
  rather than returned as an `Err(...)`: a program's own error handling must not
  be able to swallow it and let an offline test "pass" without exercising the
  real path. The message names the effect and scope and points at the three ways
  to make the call legitimate — add an `implement` block, record a golden trace,
  or opt in with `--allow-live`.
  """

  defexception [:effect, :scope, :message]

  @type t :: %__MODULE__{
          effect: String.t(),
          scope: String.t() | nil,
          message: String.t()
        }

  @doc """
  Builds a blocked-effect error for `effect` at `scope` (a host for `http.out`,
  a model for `model`, or nil when unscoped).
  """
  @spec new(String.t(), String.t() | nil) :: t()
  def new(effect, scope) when is_binary(effect) do
    target = if scope, do: "#{effect}:#{scope}", else: effect

    message =
      "Live effect blocked under `skein test`: #{describe(effect, scope)}. " <>
        "Offline tests never reach the network unless you opt in. To fix, either " <>
        "add an `implement` block for this capability in the scenario, run it as a " <>
        "golden test against a recorded trace, or allow it explicitly with " <>
        "`--allow-live #{target}`."

    %__MODULE__{effect: effect, scope: scope, message: message}
  end

  defp describe("http.out", nil), do: "an outbound HTTP request"
  defp describe("http.out", host), do: "an outbound HTTP request to #{host}"
  defp describe("model", nil), do: "an LLM call"
  defp describe("model", model), do: "an LLM call to model #{model}"
  defp describe(effect, nil), do: "a #{effect} effect"
  defp describe(effect, scope), do: "a #{effect} effect (#{scope})"
end
