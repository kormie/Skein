defmodule Skein.Runtime.TimerTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.TestPolicy
  alias Skein.Runtime.Timer

  setup do
    # Reset BEFORE each test as well as after: the Timer registry is
    # app-global and other suites can leave timers behind. The
    # list_timers/0 emptiness test depends on this pre-test reset (#338).
    Timer.reset_all()

    on_exit(fn ->
      Timer.reset_all()
      CapabilityStack.clear()
      TestPolicy.clear()
    end)
  end

  # Helper to call Timer.after/4 (reserved word in Elixir)
  defp timer_after(group \\ nil, delay_ms, callback, caps) do
    apply(Timer, :after, [group, delay_ms, callback, caps])
  end

  # Resolves the "uuid" effect through the active capability stack, returning the
  # provider's value or :no_provider — used to observe envelope propagation.
  defp resolve_uuid do
    case CapabilityStack.resolve("uuid") do
      {:implement, provider} -> provider.()
      :no_provider -> :no_provider
    end
  end

  describe "task bodies (after/5, interval/5)" do
    @wildcard [%{kind: "timer", params: []}]

    test "a one-shot timer with a work fn runs the body on fire" do
      test_pid = self()

      assert {:ok, _ref} =
               apply(Timer, :after, [
                 nil,
                 10,
                 "notify",
                 fn -> send(test_pid, :work_ran) end,
                 @wildcard
               ])

      assert_receive :work_ran, 1000
    end

    test "a recurring timer with a work fn runs the body on every fire" do
      test_pid = self()

      assert {:ok, ref} =
               Timer.interval(
                 nil,
                 10,
                 "poll",
                 fn -> send(test_pid, :tick) end,
                 @wildcard
               )

      assert_receive :tick, 1000
      assert_receive :tick, 1000

      Timer.cancel(nil, ref, @wildcard)
    end

    test "a crashing work body does not take down the timer manager" do
      test_pid = self()

      assert {:ok, _ref} =
               apply(Timer, :after, [nil, 10, "boom", fn -> raise "task crash" end, @wildcard])

      # A later timer still fires — the manager survived the crash.
      assert {:ok, _ref2} =
               apply(Timer, :after, [
                 nil,
                 30,
                 "after-crash",
                 fn -> send(test_pid, :still_alive) end,
                 @wildcard
               ])

      assert_receive :still_alive, 1000
      assert Process.whereis(Timer) != nil
    end

    test "scoped labels apply to work-body timers" do
      assert {:error, _} =
               apply(Timer, :after, [
                 "wrong-group",
                 10,
                 "task",
                 fn -> :ok end,
                 [%{kind: "timer", params: ["maintenance"]}]
               ])
    end
  end

  describe "scenario capability-context propagation to work bodies (#282)" do
    test "after/5 work body inherits the active capability envelope" do
      parent = self()
      caps = [%{kind: "timer", params: []}]
      envelope = %{tool: "T", providers: %{"uuid" => fn -> "FROM-ENVELOPE" end}}

      CapabilityStack.with_envelope(envelope, fn ->
        work = fn -> send(parent, {:resolved, resolve_uuid()}) end
        assert {:ok, _ref} = apply(Timer, :after, [nil, 5, "notify", work, caps])
      end)

      assert_receive {:resolved, "FROM-ENVELOPE"}, 1000
    end

    test "interval/5 work body inherits the blocked-live test policy" do
      parent = self()
      caps = [%{kind: "timer", params: []}]

      ref =
        TestPolicy.with_policy([], fn ->
          work = fn ->
            send(parent, {:blocked, TestPolicy.block_live?("http.out", "api.stripe.com")})
          end

          assert {:ok, ref} = Timer.interval(nil, 10, "poll", work, caps)
          ref
        end)

      assert_receive {:blocked, true}, 1000
      Timer.cancel(nil, ref, caps)
    end
  end

  describe "after/4" do
    test "fires callback after delay" do
      test_pid = self()

      assert {:ok, ref} =
               timer_after(50, fn -> send(test_pid, :fired) end, [%{kind: "timer", params: []}])

      assert is_binary(ref)
      assert_receive :fired, 1000
    end

    test "fires only once" do
      test_pid = self()

      {:ok, _ref} =
        timer_after(50, fn -> send(test_pid, :fired) end, [%{kind: "timer", params: []}])

      assert_receive :fired, 1000
      refute_receive :fired, 200
    end

    test "timer with zero delay fires immediately" do
      test_pid = self()

      {:ok, _ref} =
        timer_after(0, fn -> send(test_pid, :immediate) end, [%{kind: "timer", params: []}])

      assert_receive :immediate, 1000
    end

    test "returns unique refs for each timer" do
      noop = fn -> :ok end
      {:ok, ref1} = timer_after(1000, noop, [%{kind: "timer", params: []}])
      {:ok, ref2} = timer_after(1000, noop, [%{kind: "timer", params: []}])
      assert ref1 != ref2
    end

    test "accepts a string task name (compiled timer.after calls) as a named no-op" do
      assert {:ok, ref} =
               timer_after("maintenance", 10, "send-notification", [
                 %{kind: "timer", params: ["maintenance"]}
               ])

      assert is_binary(ref)
      # The fire is a named no-op; just make sure nothing crashes
      Process.sleep(50)
    end
  end

  describe "scoped capability labels" do
    test "permits a group matching the declared label" do
      assert {:ok, _ref} =
               timer_after("maintenance", 1000, fn -> :ok end, [
                 %{kind: "timer", params: ["maintenance"]}
               ])
    end

    test "blocks a group outside the declared label" do
      assert {:error, message} =
               timer_after("billing", 1000, fn -> :ok end, [
                 %{kind: "timer", params: ["maintenance"]}
               ])

      assert message =~ "billing"
      assert message =~ "maintenance"
    end

    test "blocks a nil group when the declaration is scoped" do
      assert {:error, _} =
               timer_after(1000, fn -> :ok end, [%{kind: "timer", params: ["maintenance"]}])
    end

    test "interval blocks a group outside the declared label" do
      assert {:error, _} =
               Timer.interval("billing", 1000, fn -> :ok end, [
                 %{kind: "timer", params: ["maintenance"]}
               ])
    end

    test "cancel blocks a group outside the declared label" do
      assert {:error, _} =
               Timer.cancel("billing", "some-ref", [%{kind: "timer", params: ["maintenance"]}])
    end

    test "records the group on the trace span" do
      Skein.Runtime.Trace.init()

      {:ok, _ref} =
        timer_after("maintenance", 1000, fn -> :ok end, [
          %{kind: "timer", params: ["maintenance"]}
        ])

      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1[:kind] == :timer and &1[:method] == :after))

      assert span
      assert span[:group] == "maintenance"
    end
  end

  describe "interval/4" do
    test "fires callback repeatedly" do
      test_pid = self()

      {:ok, _ref} =
        Timer.interval(nil, 50, fn -> send(test_pid, :tick) end, [%{kind: "timer", params: []}])

      assert_receive :tick, 1000
      assert_receive :tick, 1000
    end

    test "returns a string ref" do
      {:ok, ref} =
        Timer.interval(nil, 1000, fn -> :ok end, [%{kind: "timer", params: []}])

      assert is_binary(ref)
    end
  end

  describe "cancel/3" do
    test "cancels a pending after timer" do
      test_pid = self()

      {:ok, ref} =
        timer_after(500, fn -> send(test_pid, :should_not_fire) end, [
          %{kind: "timer", params: []}
        ])

      assert {:ok, ^ref} = Timer.cancel(nil, ref, [%{kind: "timer", params: []}])
      refute_receive :should_not_fire, 700
    end

    test "cancels a recurring interval timer" do
      test_pid = self()

      {:ok, ref} =
        Timer.interval(nil, 50, fn -> send(test_pid, :tick) end, [%{kind: "timer", params: []}])

      # Let it fire once
      assert_receive :tick, 1000

      # Cancel it
      assert {:ok, ^ref} = Timer.cancel(nil, ref, [%{kind: "timer", params: []}])
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
      assert {:ok, "nonexistent-ref"} =
               Timer.cancel(nil, "nonexistent-ref", [%{kind: "timer", params: []}])
    end
  end

  describe "list_timers/0" do
    test "returns empty list when no timers" do
      assert Timer.list_timers() == []
    end

    test "returns refs of active timers" do
      {:ok, ref1} = timer_after(5000, fn -> :ok end, [%{kind: "timer", params: []}])
      {:ok, ref2} = timer_after(5000, fn -> :ok end, [%{kind: "timer", params: []}])

      timers = Timer.list_timers()
      assert ref1 in timers
      assert ref2 in timers
    end

    test "does not include cancelled timers" do
      {:ok, ref1} = timer_after(5000, fn -> :ok end, [%{kind: "timer", params: []}])
      {:ok, ref2} = timer_after(5000, fn -> :ok end, [%{kind: "timer", params: []}])

      Timer.cancel(nil, ref1, [%{kind: "timer", params: []}])

      timers = Timer.list_timers()
      refute ref1 in timers
      assert ref2 in timers
    end
  end

  describe "reset_all/0" do
    test "cancels all timers" do
      test_pid = self()

      {:ok, _ref} = timer_after(500, fn -> send(test_pid, :a) end, [%{kind: "timer", params: []}])
      {:ok, _ref} = timer_after(500, fn -> send(test_pid, :b) end, [%{kind: "timer", params: []}])

      Timer.reset_all()

      refute_receive :a, 700
      refute_receive :b, 700
    end
  end
end
