defmodule Skein.Integration.TypedStoreTest do
  @moduledoc """
  Typed store tables end to end (C5/#255): the capability's record type
  flows through the analyzer (typed signatures, argument checks), codegen
  (the derived JSON Schema rides every `put`), and the runtime (schema-
  checked writes; misses are `Err(StoreError.NotFound)`).
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("compile failed: #{inspect(errors)}")
    end
  end

  setup do
    Skein.Runtime.Store.clear_all()
    on_exit(fn -> Skein.Runtime.Store.clear_all() end)
    :ok
  end

  @source """
  module TypedGames {
    capability store.table("typed_games", Game)
    capability uuid

    type Game {
      id: Uuid @primary
      name: String
      score: Int
    }

    fn create(name: String) -> Result[Game, StoreError] {
      store.typed_games.put(Game { id: uuid.new(), name: name, score: 0 })
    }

    fn read(id: Uuid) -> Result[Game, StoreError] {
      store.typed_games.get(id)
    }

    fn read_missing() -> String {
      match store.typed_games.get(uuid.new()) {
        Ok(_) -> "found"
        Err(StoreError.NotFound) -> "missing"
        Err(_) -> "other"
      }
    }

    fn all_names() -> Result[List[String], StoreError] {
      match store.typed_games.query({}) {
        Ok(games) -> Ok(names_of(games))
        Err(e) -> Err(e)
      }
    }

    fn names_of(games: List[Game]) -> List[String] {
      List.map(games, &name_of)
    }

    fn name_of(g: Game) -> String { g.name }

    fn remove(id: Uuid) -> Result[Uuid, StoreError] {
      store.typed_games.delete(id)
    }
  }
  """

  test "typed round trip: put a nominal record, get by @primary key, query, delete" do
    mod = compile!(@source)

    assert {:ok, game} = mod.create("chess")
    assert game.name == "chess"

    assert {:ok, fetched} = mod.read(game.id)
    assert fetched.score == 0

    assert mod.read_missing() == "missing"

    assert {:ok, _} = mod.create("go")
    assert {:ok, names} = mod.all_names()
    assert Enum.sort(names) == ["chess", "go"]

    assert {:ok, _} = mod.remove(game.id)

    assert {:error, :not_found} =
             Skein.Runtime.Store.get("typed_games", game.id, [
               %{kind: "store.table", params: ["typed_games"]}
             ])
  end

  test "the query result is typed: List[Game] flows into typed helpers" do
    mod = compile!(@source)
    assert {:ok, _} = mod.create("shogi")
    assert {:ok, ["shogi"]} = mod.all_names()
  end

  test "runtime schema check rejects a wrong-shaped write (defense in depth)" do
    # Direct Elixir caller with the schema the compiler would thread.
    schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "format" => "uuid"},
        "name" => %{"type" => "string"},
        "score" => %{"type" => "integer"}
      },
      "required" => ["id", "name", "score"]
    }

    caps = [%{kind: "store.table", params: ["typed_games"]}]

    assert {:error, {:failed, reason}} =
             Skein.Runtime.Store.put(
               "typed_games",
               %{"id" => "00000000-0000-4000-8000-000000000001", "name" => "x"},
               schema,
               caps
             )

    assert reason =~ "score"
  end
end
