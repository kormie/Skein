defmodule Skein.StdlibTypesTest do
  @moduledoc "Tests for Option, Result, Uuid, Instant, Duration stdlib modules (1d + 1e)"
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Compiler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # ---------------------------------------------------------------
  # Option stdlib
  # ---------------------------------------------------------------
  describe "Option.is_some and Option.is_none" do
    test "checks some/none status" do
      mod =
        compile!("""
        module OptCheck {
          fn check_some(o: Option[Int]) -> Bool {
            Option.is_some(o)
          }
          fn check_none(o: Option[Int]) -> Bool {
            Option.is_none(o)
          }
        }
        """)

      assert mod.check_some({:some, 42}) == true
      assert mod.check_some(:none) == false
      assert mod.check_none(:none) == true
      assert mod.check_none({:some, 42}) == false
    end
  end

  describe "Option.unwrap" do
    test "unwraps Some value" do
      mod =
        compile!("""
        module OptUnwrap {
          fn get(o: Option[Int]) -> Int {
            Option.unwrap(o)
          }
        }
        """)

      assert mod.get({:some, 42}) == 42
    end

    test "unwrap on None raises" do
      mod =
        compile!("""
        module OptUnwrapFail {
          fn get(o: Option[Int]) -> Int {
            Option.unwrap(o)
          }
        }
        """)

      assert_raise RuntimeError, fn -> mod.get(:none) end
    end
  end

  describe "Option.map" do
    test "maps over Some, passes None through" do
      # Test via Elixir direct calls since FnRef for lambdas isn't needed
      assert Skein.Runtime.Stdlib.Option.map({:some, 5}, &(&1 * 2)) == {:some, 10}
      assert Skein.Runtime.Stdlib.Option.map(:none, &(&1 * 2)) == :none
    end
  end

  describe "Option.flat_map" do
    test "flat maps over Some" do
      assert Skein.Runtime.Stdlib.Option.flat_map({:some, 5}, fn x ->
               if x > 0, do: {:some, x * 2}, else: :none
             end) == {:some, 10}

      assert Skein.Runtime.Stdlib.Option.flat_map(:none, fn _ -> {:some, 1} end) == :none
    end
  end

  # ---------------------------------------------------------------
  # Result stdlib
  # ---------------------------------------------------------------
  describe "Result.is_ok and Result.is_err" do
    test "checks ok/err status" do
      mod =
        compile!("""
        module ResCheck {
          fn ok(r: Result[Int, String]) -> Bool {
            Result.is_ok(r)
          }
          fn err(r: Result[Int, String]) -> Bool {
            Result.is_err(r)
          }
        }
        """)

      assert mod.ok({:ok, 42}) == true
      assert mod.ok({:error, "oops"}) == false
      assert mod.err({:error, "oops"}) == true
      assert mod.err({:ok, 42}) == false
    end
  end

  describe "Result.unwrap" do
    test "unwraps Ok value" do
      mod =
        compile!("""
        module ResUnwrap {
          fn get(r: Result[Int, String]) -> Int {
            Result.unwrap(r)
          }
        }
        """)

      assert mod.get({:ok, 42}) == 42
    end

    test "unwrap on Err raises" do
      mod =
        compile!("""
        module ResUnwrapFail {
          fn get(r: Result[Int, String]) -> Int {
            Result.unwrap(r)
          }
        }
        """)

      assert_raise RuntimeError, fn -> mod.get({:error, "bad"}) end
    end
  end

  describe "Result.ok and Result.err constructors" do
    test "creates Ok and Err values" do
      mod =
        compile!("""
        module ResConstruct {
          fn make_ok(v: Int) -> Result[Int, String] {
            Result.ok(v)
          }
          fn make_err(msg: String) -> Result[Int, String] {
            Result.err(msg)
          }
        }
        """)

      assert mod.make_ok(42) == {:ok, 42}
      assert mod.make_err("oops") == {:error, "oops"}
    end
  end

  describe "Result.map" do
    test "maps over Ok, passes Err through" do
      assert Skein.Runtime.Stdlib.Result.map({:ok, 5}, &(&1 * 2)) == {:ok, 10}
      assert Skein.Runtime.Stdlib.Result.map({:error, "oops"}, &(&1 * 2)) == {:error, "oops"}
    end
  end

  describe "Result.map_err" do
    test "maps over Err, passes Ok through" do
      assert Skein.Runtime.Stdlib.Result.map_err({:ok, 5}, &String.upcase/1) == {:ok, 5}

      assert Skein.Runtime.Stdlib.Result.map_err({:error, "oops"}, &String.upcase/1) ==
               {:error, "OOPS"}
    end
  end

  # ---------------------------------------------------------------
  # Uuid stdlib
  # ---------------------------------------------------------------
  describe "Uuid.new" do
    test "generates a valid UUID" do
      mod =
        compile!("""
        module UuidNew {
          fn make() -> Uuid {
            Uuid.new()
          }
        }
        """)

      uuid = mod.make()
      assert is_binary(uuid)
      assert String.length(uuid) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
               uuid
             )
    end
  end

  describe "Uuid.parse" do
    test "parses valid UUIDs" do
      mod =
        compile!("""
        module UuidParse {
          fn check(s: String) -> Result[Uuid, String] {
            Uuid.parse(s)
          }
        }
        """)

      assert {:ok, _} = mod.check("550e8400-e29b-41d4-a716-446655440000")
      assert {:error, _} = mod.check("not-a-uuid")
    end
  end

  # ---------------------------------------------------------------
  # Instant stdlib
  # ---------------------------------------------------------------
  describe "Instant.now" do
    test "returns current time as ISO 8601" do
      mod =
        compile!("""
        module InstantNow {
          fn current() -> Instant {
            Instant.now()
          }
        }
        """)

      now = mod.current()
      assert is_binary(now)
      assert String.contains?(now, "T")
      assert {:ok, _, _} = DateTime.from_iso8601(now)
    end
  end

  describe "Instant.parse" do
    test "parses valid ISO 8601" do
      mod =
        compile!("""
        module InstantParse {
          fn check(s: String) -> Result[Instant, String] {
            Instant.parse(s)
          }
        }
        """)

      assert {:ok, _} = mod.check("2026-01-01T00:00:00Z")
      assert {:error, _} = mod.check("not-a-date")
    end
  end

  describe "Instant.diff" do
    test "returns difference in seconds" do
      mod =
        compile!("""
        module InstantDiff {
          fn delta(a: Instant, b: Instant) -> Int {
            Instant.diff(a, b)
          }
        }
        """)

      assert mod.delta("2026-01-01T01:00:00Z", "2026-01-01T00:00:00Z") == 3600
    end
  end

  describe "Instant.is_before and Instant.is_after" do
    test "compares instants" do
      mod =
        compile!("""
        module InstantCompare {
          fn before(a: Instant, b: Instant) -> Bool {
            Instant.is_before(a, b)
          }
          fn after_than(a: Instant, b: Instant) -> Bool {
            Instant.is_after(a, b)
          }
        }
        """)

      a = "2026-01-01T00:00:00Z"
      b = "2026-06-01T00:00:00Z"
      assert mod.before(a, b) == true
      assert mod.after_than(a, b) == false
      assert mod.after_than(b, a) == true
    end
  end

  describe "Instant.add and Instant.subtract" do
    test "adds and subtracts duration" do
      mod =
        compile!("""
        module InstantMath {
          fn later(t: Instant, secs: Duration) -> Instant {
            Instant.add(t, secs)
          }
          fn earlier(t: Instant, secs: Duration) -> Instant {
            Instant.subtract(t, secs)
          }
        }
        """)

      base = "2026-01-01T00:00:00Z"
      assert mod.later(base, 3600) =~ "2026-01-01T01:00:00"
      assert mod.earlier(base, 3600) =~ "2025-12-31T23:00:00"
    end
  end

  # ---------------------------------------------------------------
  # Duration stdlib
  # ---------------------------------------------------------------
  describe "Duration constructors" do
    test "creates durations from units" do
      mod =
        compile!("""
        module DurCreate {
          fn secs(n: Int) -> Duration {
            Duration.seconds(n)
          }
          fn mins(n: Int) -> Duration {
            Duration.minutes(n)
          }
          fn hrs(n: Int) -> Duration {
            Duration.hours(n)
          }
          fn dys(n: Int) -> Duration {
            Duration.days(n)
          }
        }
        """)

      assert mod.secs(30) == 30
      assert mod.mins(5) == 300
      assert mod.hrs(2) == 7200
      assert mod.dys(1) == 86400
    end
  end

  describe "Duration.to_seconds" do
    test "returns duration in seconds" do
      mod =
        compile!("""
        module DurSecs {
          fn to_secs(d: Duration) -> Int {
            Duration.to_seconds(d)
          }
        }
        """)

      assert mod.to_secs(3600) == 3600
    end
  end

  describe "Duration.to_string" do
    test "formats duration" do
      mod =
        compile!("""
        module DurStr {
          fn show(d: Duration) -> String {
            Duration.to_string(d)
          }
        }
        """)

      assert mod.show(30) == "30s"
      assert mod.show(300) == "5m"
      assert mod.show(7200) == "2h"
      assert mod.show(86400) == "1d"
    end
  end

  # ---------------------------------------------------------------
  # Property tests — types
  # ---------------------------------------------------------------
  describe "Uuid properties" do
    property "Uuid.new always generates valid UUIDs" do
      mod =
        compile!("""
        module PropUuid {
          fn make() -> Uuid {
            Uuid.new()
          }
        }
        """)

      check all(_ <- constant(nil), max_runs: 50) do
        uuid = mod.make()
        assert String.length(uuid) == 36
        assert {:ok, _} = Skein.Runtime.Stdlib.Uuid.parse(uuid)
      end
    end
  end

  describe "Duration properties" do
    property "Duration.minutes(n) == Duration.seconds(n * 60)" do
      mod =
        compile!("""
        module PropDur {
          fn secs(n: Int) -> Duration {
            Duration.seconds(n)
          }
          fn mins(n: Int) -> Duration {
            Duration.minutes(n)
          }
        }
        """)

      check all(n <- integer(0..1000)) do
        assert mod.mins(n) == mod.secs(n * 60)
      end
    end
  end

  describe "Result properties" do
    property "Result.ok then Result.unwrap round-trips" do
      mod =
        compile!("""
        module PropResult {
          fn wrap(v: Int) -> Result[Int, String] {
            Result.ok(v)
          }
          fn unwrap(r: Result[Int, String]) -> Int {
            Result.unwrap(r)
          }
        }
        """)

      check all(n <- integer()) do
        assert mod.unwrap(mod.wrap(n)) == n
      end
    end
  end
end
