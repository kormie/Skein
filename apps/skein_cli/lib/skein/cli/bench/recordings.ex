defmodule Skein.CLI.Bench.Recordings do
  @moduledoc """
  Persistence for benchmark generation recordings (#320).

  A live benchmark run records every raw generator response, keyed by task
  id, in iteration order. Replay mode plays the recorded responses back
  through the same compile-fix loop — no LLM calls, fully deterministic —
  so CI and release-readiness re-measure the recorded run against the
  *current* compiler: if a recorded solution stops compiling, the language
  moved under it.
  """

  @type t :: %{
          model: String.t() | nil,
          recorded_at: String.t() | nil,
          responses: %{String.t() => [String.t()]}
        }

  @doc """
  Writes recordings as pretty-printed JSON.

  `responses` maps task id to raw generator responses in iteration order.
  """
  @spec save(Path.t(), %{String.t() => [String.t()]}, keyword()) :: :ok | {:error, String.t()}
  def save(path, responses, opts \\ []) do
    document = %{
      "version" => 1,
      "model" => Keyword.get(opts, :model),
      "recorded_at" => Keyword.get(opts, :recorded_at),
      "responses" => responses
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(document, pretty: true),
         :ok <- File.write(path, json <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, "could not save recordings to #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Loads recordings saved by `save/3`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"responses" => responses} = document} when is_map(responses) <-
           Jason.decode(raw) do
      {:ok,
       %{
         model: document["model"],
         recorded_at: document["recorded_at"],
         responses: responses
       }}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "recordings at #{path} are not valid JSON: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "could not read recordings at #{path}: #{inspect(reason)}"}

      {:ok, _other} ->
        {:error, "recordings at #{path} have no \"responses\" object"}
    end
  end

  @doc """
  A `Skein.CLI.Bench` generator that replays recorded responses.

  Iteration N of a task returns the Nth recorded response; running past
  the end of a task's recording is a generator error (the benchmark
  reports the task as failed rather than hanging or calling out).
  """
  @spec replay_generator(t()) :: Skein.CLI.Bench.generator()
  def replay_generator(%{responses: responses}) do
    fn task, iteration, _system, _user ->
      case responses |> Map.get(task.id, []) |> Enum.at(iteration - 1) do
        nil -> {:error, "recording exhausted for #{task.id} at iteration #{iteration}"}
        response -> {:ok, response}
      end
    end
  end
end
