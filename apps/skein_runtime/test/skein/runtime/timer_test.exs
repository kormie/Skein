defmodule Skein.Runtime.TimerTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Timer

  setup do
    on_exit(fn -> Timer.reset_all() end)
  end

  # Helper to call Timer.after/3 (reserved word in Elixir)
  defp timer_after(delay_ms, callback, caps) do
    apply(Timer, :after, [delay_ms, callback, caps])
  end

  describe "after/3" do
    test "fires callback after delay" do
      test_pid = self()

      assert {:ok, ref} =
               timer_after(50, fn -> send(test_pid, :fired) end, [])

      assert is_binary(ref)
      assert_receive :fired, 1000
    end

    test "fires only once" do
      test_pid = self()

      {:ok, _ref} =
        timer_after(50, fn -> send(test_pid, :fired) end, [])

      assert_receive :fired, 1000
      refute_receive :fired, 200
    end

    test "timer with zero delay fires immediately" do
      test_pid = self()

      {:ok, _ref} =
        timer_after(0, fn -> send(test_pid, :immediate) end, [])

      assert_receive :immediate, 1000
    end

    test "returns unique refs for each timer" do
      noop = fn -> :ok end
      {:ok, ref1} = timer_after(1000, noop, [])
      {:ok, ref2} = timer_after(1000, noop, [])
      assert ref1 != ref2
    end
  end

  describe "interval/3" do
    test "fires callback repeatedly" do
      test_pid = self()

      {:ok, _ref} =
        Timer.interval(50, fn -> send(test_pid, :tick) end, [])

      assert_receive :tick, 1000
      assert_receive :tick, 1000
    end

    test "returns a string ref" do
      {:ok, ref} =
        Timer.interval(1000, fn -> :ok end, [])

      assert is_binary(ref)
    end
  end

  describe "cancel/2" do
    test "cancels a pending after timer" do
      test_pid = self()

      {:ok, ref} =
        timer_after(500, fn -> send(test_pid, :should_not_fire) end, [])

      assert :ok = Timer.cancel(ref, [])
      refute_receive :should_not_fire, 700
    end

    test "cancels a recurring interval timer" do
      test_pid = self()

      {:ok, ref} =
        Timer.interval(50, fn -> send(test_pid, :tick) end, [])

      # Let it fire once
      assert_receive :tick, 1000

      # Cancel it
      assert :ok = Timer.cancel(ref, [])
      Process.sleep(150)

      # Drain any remaining messages that were in-flight
      receive do
        :tick -> :ok
      after
        0 -> :ok
      end

      refute_receive :tick, 200
    end

    test "cancelling a nonexistent ref returns :ok" do
      assert :ok = Timer.cancel("nonexistent-ref", [])
    end
  end

  describe "list_timers/0" do
    test "returns empty list when no timers" do
      assert Timer.list_timers() == []
    end

    test "returns refs of active timers" do
      {:ok, ref1} = timer_after(5000, fn -> :ok end, [])
      {:ok, ref2} = timer_after(5000, fn -> :ok end, [])

      timers = Timer.list_timers()
      assert ref1 in timers
      assert ref2 in timers
    end

    test "does not include cancelled timers" do
      {:ok, ref1} = timer_after(5000, fn -> :ok end, [])
      {:ok, ref2} = timer_after(5000, fn -> :ok end, [])

      Timer.cancel(ref1, [])

      timers = Timer.list_timers()
      refute ref1 in timers
      assert ref2 in timers
    end
  end

  describe "reset_all/0" do
    test "cancels all timers" do
      test_pid = self()

      {:ok, _ref} = timer_after(500, fn -> send(test_pid, :a) end, [])
      {:ok, _ref} = timer_after(500, fn -> send(test_pid, :b) end, [])

      Timer.reset_all()

      refute_receive :a, 700
      refute_receive :b, 700
    end
  end
end
