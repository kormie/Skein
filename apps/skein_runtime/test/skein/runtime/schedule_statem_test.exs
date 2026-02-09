defmodule Skein.Runtime.ScheduleStatemTest do
  @moduledoc """
  PropCheck stateful (state machine) test for Skein.Runtime.Schedule.

  Models the schedule dispatch system as a map of cron expressions to
  handler counts and verifies that register, trigger, list, and reset
  operations maintain consistency.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.Schedule

  # ------------------------------------------------------------------
  # Model state: %{cron_expr => handler_count}
  # ------------------------------------------------------------------

  def initial_state, do: %{}

  # ------------------------------------------------------------------
  # Command generation
  # ------------------------------------------------------------------

  def command(state) do
    always_available = [
      {:call, __MODULE__, :do_register, [cron_gen()]},
      {:call, __MODULE__, :do_list_schedules, []},
      {:call, __MODULE__, :do_reset, []}
    ]

    # If schedules exist, trigger and register on them
    existing_cmds =
      case Map.keys(state) do
        [] ->
          []

        crons ->
          [
            {:call, __MODULE__, :do_trigger, [oneof(crons)]},
            {:call, __MODULE__, :do_register, [oneof(crons)]}
          ]
      end

    # Trigger on non-registered crons
    trigger_new = [{:call, __MODULE__, :do_trigger, [cron_gen()]}]

    oneof(always_available ++ existing_cmds ++ trigger_new)
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp cron_gen do
    let {minute, hour, day, month, weekday} <-
          {minute_gen(), hour_gen(), day_gen(), month_gen(), weekday_gen()} do
      "#{minute} #{hour} #{day} #{month} #{weekday}"
    end
  end

  defp minute_gen do
    oneof([
      exactly("*"),
      let(n <- range(0, 59), do: Integer.to_string(n)),
      let(n <- range(1, 30), do: "*/#{n}")
    ])
  end

  defp hour_gen do
    oneof([
      exactly("*"),
      let(n <- range(0, 23), do: Integer.to_string(n))
    ])
  end

  defp day_gen do
    oneof([
      exactly("*"),
      let(n <- range(1, 31), do: Integer.to_string(n))
    ])
  end

  defp month_gen do
    oneof([
      exactly("*"),
      let(n <- range(1, 12), do: Integer.to_string(n))
    ])
  end

  defp weekday_gen do
    oneof([
      exactly("*"),
      let(n <- range(0, 6), do: Integer.to_string(n))
    ])
  end

  # ------------------------------------------------------------------
  # Command implementations
  # ------------------------------------------------------------------

  def do_register(cron_expr) do
    Schedule.register_fn(cron_expr, fn _ctx -> :ok end)
  end

  def do_trigger(cron_expr) do
    Schedule.trigger(cron_expr)
  end

  def do_list_schedules do
    Schedule.list_schedules()
  end

  def do_reset do
    Schedule.reset_all()
  end

  # ------------------------------------------------------------------
  # Preconditions
  # ------------------------------------------------------------------

  def precondition(_state, {:call, _, _, _}), do: true

  # ------------------------------------------------------------------
  # Postconditions
  # ------------------------------------------------------------------

  def postcondition(_state, {:call, _, :do_register, [_cron]}, result) do
    result == :ok
  end

  def postcondition(_state, {:call, _, :do_trigger, [_cron]}, result) do
    result == :ok
  end

  def postcondition(state, {:call, _, :do_list_schedules, []}, result) do
    expected = Map.keys(state) |> Enum.sort()
    is_list(result) and Enum.sort(result) == expected
  end

  def postcondition(_state, {:call, _, :do_reset, []}, result) do
    result == :ok
  end

  # ------------------------------------------------------------------
  # Next state
  # ------------------------------------------------------------------

  def next_state(state, _result, {:call, _, :do_register, [cron]}) do
    Map.update(state, cron, 1, &(&1 + 1))
  end

  def next_state(state, _result, {:call, _, :do_trigger, [_cron]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_list_schedules, []}) do
    state
  end

  def next_state(_state, _result, {:call, _, :do_reset, []}) do
    %{}
  end

  # ------------------------------------------------------------------
  # Property
  # ------------------------------------------------------------------

  property "schedule operations maintain consistency with model", [:verbose, {:numtests, 50}] do
    forall cmds <- commands(__MODULE__) do
      Schedule.reset_all()

      {history, state, result} = run_commands(__MODULE__, cmds)

      Schedule.reset_all()

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        """)
      )
    end
  end
end
