defmodule Skein.CLI.Config do
  @moduledoc """
  skein.toml parsing and environment profile resolution.

  Skein source never changes between environments — `capability
  model("anthropic", "claude-opus-4-8")` is the code's contract whether
  traffic goes to Anthropic or a local model server. The `[llm]` section
  of skein.toml (and per-environment `[env.<name>.llm]` overrides,
  selected via `SKEIN_ENV` or `--env`) decides which backend serves the
  calls (issue #107):

      [llm]                      # default: production
      backend = "anthropic"

      [env.dev.llm]
      backend = "openai_compatible"
      base_url = "http://localhost:10240/v1"
      api_key_env = "OMLX_API_KEY"        # optional; most local servers need none
      model_map = { "claude-opus-4-8" = "mlx-community/Qwen3-30B" }

      [env.prod.llm]
      backend = "bedrock"                 # Amazon Bedrock (SigV4, AWS env credentials)
      region = "us-west-2"
      model_map = { "claude-sonnet-4-6" = "global.anthropic.claude-sonnet-4-6" }

  The parser covers the TOML subset skein.toml uses: `[table]` headers
  (dotted), `key = "string"` / `key = 123` pairs, inline string tables,
  comments, and blank lines.

  Anything outside that subset is tolerated, not fatal: unknown keys with
  unparseable values (floats, arrays, dates, multi-line forms) and unknown
  table forms are skipped, so a skein.toml written for a future Skein
  version still parses on 1.0. Parse errors are reported only for the
  known `[llm]` profile keys, where a bad value means a misconfigured
  backend rather than a key from the future.
  """

  @llm_profile_keys ~w(backend base_url api_key_env model_map region)

  alias Skein.Runtime.Llm

  @doc """
  Parses skein.toml content into a nested string-keyed map.

  Returns `{:ok, map}` or `{:error, message}` naming the offending line.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({%{}, []}, fn {line, number}, {acc, table_path} ->
      trimmed = String.trim(line)

      case parse_line(trimmed) do
        :skip ->
          {:cont, {acc, table_path}}

        {:table, path} ->
          {:cont, {acc, path}}

        {:pair, _key, _value} when table_path == :unknown ->
          {:cont, {acc, table_path}}

        {:pair, key, value} ->
          {:cont, {put_nested(acc, table_path ++ [key], value), table_path}}

        :error ->
          cond do
            String.starts_with?(trimmed, "[") ->
              # Unknown table form (e.g. [[array.of.tables]]): skip the
              # table and everything in it
              {:cont, {acc, :unknown}}

            known_llm_key_failure?(table_path, trimmed) ->
              {:halt, {:error, "Cannot parse skein.toml line #{number}: #{trimmed}"}}

            true ->
              # Unknown key or value form from a future version — ignored
              {:cont, {acc, table_path}}
          end
      end
    end)
    |> case do
      {:error, _} = error -> error
      {parsed, _path} -> {:ok, parsed}
    end
  end

  # A parse failure is fatal only for the known [llm] profile keys, where
  # a bad value is a misconfiguration the user must hear about.
  defp known_llm_key_failure?(table_path, line) do
    in_llm_section?(table_path) and
      Enum.any?(@llm_profile_keys, fn key ->
        Regex.match?(~r/^#{key}\s*=/, line)
      end)
  end

  defp in_llm_section?(["llm"]), do: true
  defp in_llm_section?(["env", _name, "llm"]), do: true
  defp in_llm_section?(_), do: false

  @doc """
  Resolves the active LLM profile from a parsed skein.toml.

  An `[env.<name>.llm]` profile wins for that environment; otherwise the
  default `[llm]` section applies; `nil` when neither exists.
  """
  @spec llm_profile(map(), String.t() | nil) :: map() | nil
  def llm_profile(parsed, nil), do: parsed["llm"]

  def llm_profile(parsed, env) when is_binary(env) do
    case parsed do
      %{"env" => %{^env => %{"llm" => profile}}} -> profile
      _ -> parsed["llm"]
    end
  end

  @doc """
  Reads the project's skein.toml and activates the resolved LLM profile
  via `Skein.Runtime.Llm.set_backend/1`.

  Returns `{:ok, description}` when a backend was set, `:noop` when there
  is no skein.toml or no LLM profile (the current backend stays), or
  `{:error, message}` for unparseable config or unusable profiles.
  """
  @spec apply_llm_profile(String.t(), String.t() | nil) ::
          {:ok, String.t()} | :noop | {:error, String.t()}
  def apply_llm_profile(project_dir, env) do
    path = Path.join(project_dir, "skein.toml")

    if File.exists?(path) do
      with {:ok, parsed} <- parse(File.read!(path)) do
        case llm_profile(parsed, env) do
          nil -> :noop
          profile -> activate(profile)
        end
      end
    else
      :noop
    end
  end

  # -- Profile activation -----------------------------------------------------

  defp activate(%{"backend" => "anthropic"}) do
    Llm.set_backend(Skein.Runtime.Llm.AnthropicBackend)
    {:ok, "llm backend: anthropic"}
  end

  defp activate(%{"backend" => "test"}) do
    Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    {:ok, "llm backend: test"}
  end

  defp activate(%{"backend" => "openai_compatible"} = profile) do
    case profile["base_url"] do
      base_url when is_binary(base_url) and base_url != "" ->
        config = %{
          base_url: base_url,
          api_key: resolve_api_key(profile["api_key_env"]),
          model_map: profile["model_map"] || %{}
        }

        Llm.set_backend({Skein.Runtime.Llm.OpenAiCompatibleBackend, config})
        {:ok, "llm backend: openai_compatible at #{base_url}"}

      _ ->
        {:error,
         "skein.toml llm profile 'openai_compatible' requires base_url " <>
           "(e.g. base_url = \"http://localhost:10240/v1\")"}
    end
  end

  # Amazon Bedrock (issue #173). Credentials resolve at call time from the
  # standard AWS env vars; only region and the model mapping live here.
  defp activate(%{"backend" => "bedrock"} = profile) do
    case bedrock_region(profile) do
      region when is_binary(region) and region != "" ->
        config = %{
          region: region,
          model_map: profile["model_map"] || %{}
        }

        config =
          case profile["base_url"] do
            base_url when is_binary(base_url) and base_url != "" ->
              Map.put(config, :base_url, base_url)

            _ ->
              config
          end

        Llm.set_backend({Skein.Runtime.Llm.BedrockBackend, config})
        {:ok, "llm backend: bedrock (#{region})"}

      _ ->
        {:error,
         "skein.toml llm profile 'bedrock' requires region " <>
           "(e.g. region = \"us-west-2\") or AWS_REGION in the environment"}
    end
  end

  defp activate(%{"backend" => other}) do
    {:error,
     "Unknown llm backend '#{other}' in skein.toml " <>
       "(expected \"anthropic\", \"bedrock\", \"openai_compatible\", or \"test\")"}
  end

  defp activate(_profile) do
    {:error, "skein.toml llm profile is missing 'backend'"}
  end

  defp resolve_api_key(env_var) when is_binary(env_var) and env_var != "" do
    System.get_env(env_var)
  end

  defp resolve_api_key(_), do: nil

  defp bedrock_region(profile) do
    profile["region"] || System.get_env("AWS_REGION")
  end

  # -- TOML-subset parsing ------------------------------------------------------

  defp parse_line(""), do: :skip
  defp parse_line("#" <> _comment), do: :skip

  defp parse_line("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [path, ""] -> {:table, path |> String.trim() |> String.split(".")}
      _ -> :error
    end
  end

  defp parse_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        with true <- Regex.match?(~r/^[A-Za-z0-9_-]+$/, key),
             {:ok, parsed} <- parse_value(String.trim(value)) do
          {:pair, key, parsed}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_value("\"" <> _ = quoted) do
    case Regex.run(~r/^"([^"]*)"(\s*#.*)?$/, quoted) do
      [_, value | _] -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_value("{" <> _ = inline) do
    case Regex.run(~r/^\{(.*)\}$/, inline) do
      [_, entries] ->
        entries
        |> String.split(",")
        |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
          case Regex.run(~r/^\s*"([^"]+)"\s*=\s*"([^"]*)"\s*$/, entry) do
            [_, key, value] -> {:cont, {:ok, Map.put(acc, key, value)}}
            _ -> {:halt, :error}
          end
        end)

      _ ->
        :error
    end
  end

  defp parse_value(other) do
    case Integer.parse(other) do
      {int, ""} -> {:ok, int}
      _ -> if other in ["true", "false"], do: {:ok, other == "true"}, else: :error
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [head | rest], value) do
    Map.put(map, head, put_nested(Map.get(map, head, %{}), rest, value))
  end
end
