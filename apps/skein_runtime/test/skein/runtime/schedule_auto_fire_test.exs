defmodule Skein.Runtime.ScheduleAutoFireTest do
  @moduledoc """
  Schedule handler auto-firing (issue #71): cron expressions are
  evaluated on a periodic tick and matching handlers fire through the
  existing dispatch path, at most once per cron minute.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Schedule

  setup do
    Schedule.reset_all()
    on_exit(fn -> Schedule.reset_all() end)
    :ok
  end

  defp dt(minute, opts \\ []) do
    %DateTime{
      year: Keyword.get(opts, :year, 2026),
      month: Keyword.get(opts, :month, 6),
      day: Keyword.get(opts, :day, 10),
      hour: Keyword.get(opts, :hour, 12),
      minute: minute,
      second: Keyword.get(opts, :second, 0),
      microsecond: {0, 0},
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }
  end

  # ------------------------------------------------------------------
  # compile_cron / cron_match?
  # ------------------------------------------------------------------

  describe "compile_cron/1" do
    test "accepts wildcard, numeric, step, range, and list fields" do
      for expr <- [
            "* * * * *",
            "*/5 * * * *",
            "30 14 1 6 0",
            "1-5 * * * *",
            "0,15,30,45 * * * *",
            "10-50/10 * * * *"
          ] do
        assert {:ok, _} = Schedule.compile_cron(expr), "expected valid: #{expr}"
      end
    end

    test "rejects out-of-range and malformed fields" do
      for expr <- [
            "60 * * * *",
            "* 24 * * *",
            "* * 0 * *",
            "* * * 13 *",
            "* * * * 8",
            "abc * * * *",
            "*/0 * * * *",
            "5-1 * * * *",
            "* * * *"
          ] do
        assert {:error, _} = Schedule.compile_cron(expr), "expected invalid: #{expr}"
      end
    end
  end

  describe "cron_match?/2" do
    test "wildcard matches any time" do
      {:ok, compiled} = Schedule.compile_cron("* * * * *")
      assert Schedule.cron_match?(compiled, dt(0))
      assert Schedule.cron_match?(compiled, dt(59))
    end

    test "step field matches multiples" do
      {:ok, compiled} = Schedule.compile_cron("*/15 * * * *")
      assert Schedule.cron_match?(compiled, dt(0))
      assert Schedule.cron_match?(compiled, dt(45))
      refute Schedule.cron_match?(compiled, dt(7))
    end

    test "numeric, range, and list fields" do
      # 2026-06-10 is a Wednesday
      {:ok, compiled} = Schedule.compile_cron("30 9-17 * * 1,3,5")
      assert Schedule.cron_match?(compiled, dt(30, hour: 9))
      refute Schedule.cron_match?(compiled, dt(31, hour: 9))
      refute Schedule.cron_match?(compiled, dt(30, hour: 8))
      # 2026-06-14 is a Sunday (weekday 0, not in 1,3,5)
      refute Schedule.cron_match?(compiled, dt(30, hour: 9, day: 14))
    end

    test "weekday 7 means Sunday, same as 0" do
      {:ok, with_seven} = Schedule.compile_cron("* * * * 7")
      {:ok, with_zero} = Schedule.compile_cron("* * * * 0")
      sunday = dt(0, day: 14)
      assert Schedule.cron_match?(with_seven, sunday)
      assert Schedule.cron_match?(with_zero, sunday)
    end

    test "restricted day-of-month and weekday combine with OR (standard cron)" do
      # Fire on the 1st of the month OR on Mondays. In July 2026:
      # the 1st is a Wednesday, the 6th is a Monday, the 10th is a Friday.
      {:ok, compiled} = Schedule.compile_cron("0 0 1 * 1")
      assert Schedule.cron_match?(compiled, dt(0, hour: 0, month: 7, day: 1))
      assert Schedule.cron_match?(compiled, dt(0, hour: 0, month: 7, day: 6))
      refute Schedule.cron_match?(compiled, dt(0, hour: 0, month: 7, day: 10))
    end
  end

  # ------------------------------------------------------------------
  # Registration validation
  # ------------------------------------------------------------------

  describe "register/3 validation" do
    test "registering an invalid cron expression is an error" do
      assert {:error, message} = Schedule.register_fn("not a cron", fn _ -> :ok end)
      assert message =~ "cron"
    end

    test "registering a valid cron expression still returns :ok" do
      assert :ok = Schedule.register_fn("*/5 * * * *", fn _ -> :ok end)
    end
  end

  # ------------------------------------------------------------------
  # Ticking and dedup
  #
  # Every deterministic test pins its cron to the simulated date
  # (2026-06-10 12:xx — forever in the past), so no stray wall-clock
  # tick, whatever its source, can ever match and fire it (#272). Only
  # the dedicated auto-tick test registers a wall-clock-matching cron.
  # ------------------------------------------------------------------

  describe "tick_at/1" do
    test "fires matching handlers and skips non-matching ones" do
      parent = self()
      :ok = Schedule.register_fn("*/10 12 10 6 *", fn _ -> send(parent, :every_ten) end)
      :ok = Schedule.register_fn("7 12 10 6 *", fn _ -> send(parent, :at_seven) end)

      Schedule.tick_at(dt(20))
      assert_receive :every_ten
      refute_receive :at_seven, 50
    end

    test "fires at most once within the same cron minute" do
      parent = self()
      :ok = Schedule.register_fn("* 12 10 6 *", fn _ -> send(parent, :fired) end)

      Schedule.tick_at(dt(5, second: 0))
      Schedule.tick_at(dt(5, second: 1))
      Schedule.tick_at(dt(5, second: 59))

      assert_receive :fired
      refute_receive :fired, 50
    end

    test "fires again in the next matching minute" do
      parent = self()
      :ok = Schedule.register_fn("* 12 10 6 *", fn _ -> send(parent, :fired) end)

      Schedule.tick_at(dt(5))
      Schedule.tick_at(dt(6))
      Schedule.tick_at(dt(7))

      assert_receive :fired
      assert_receive :fired
      assert_receive :fired
      refute_receive :fired, 50
    end

    test "manual trigger/1 still works and is not deduplicated" do
      parent = self()
      :ok = Schedule.register_fn("*/5 12 10 6 *", fn _ -> send(parent, :manual) end)

      Schedule.trigger("*/5 12 10 6 *")
      Schedule.trigger("*/5 12 10 6 *")

      assert_receive :manual
      assert_receive :manual
    end
  end

  # ------------------------------------------------------------------
  # Auto-tick wiring (the interval timer sends :tick)
  # ------------------------------------------------------------------

  test "a :tick message fires due handlers without manual intervention" do
    parent = self()
    :ok = Schedule.register_fn("* * * * *", fn _ -> send(parent, :auto_fired) end)

    # The interval timer delivers :tick; evaluation uses the wall clock.
    send(Process.whereis(Schedule), :tick)
    assert_receive :auto_fired, 500
  end

  # ------------------------------------------------------------------
  # Property: firing count over a window matches matching-minute count
  # ------------------------------------------------------------------

  property "fired count equals matching minutes for */n over any window" do
    check all(
            n <- StreamData.integer(1..30),
            start_minute <- StreamData.integer(0..59),
            window <- StreamData.integer(1..30),
            ticks_per_minute <- StreamData.integer(1..3),
            max_runs: 30
          ) do
      Schedule.reset_all()
      parent = self()
      ref = make_ref()
      # Day/month pinned to the simulated date — immune to wall-clock ticks.
      :ok = Schedule.register_fn("*/#{n} * 10 6 *", fn _ -> send(parent, {:fired, ref}) end)

      base = DateTime.new!(~D[2026-06-10], ~T[00:00:00], "Etc/UTC")

      for offset <- start_minute..(start_minute + window - 1),
          tick <- 1..ticks_per_minute do
        moment = DateTime.add(base, offset * 60 + tick, :second)
        Schedule.tick_at(moment)
      end

      fired = count_messages({:fired, ref}, 0)

      expected =
        start_minute..(start_minute + window - 1)
        |> Enum.count(fn offset -> rem(rem(offset, 60), n) == 0 end)

      assert fired == expected
    end
  end

  defp count_messages(msg, acc) do
    receive do
      ^msg -> count_messages(msg, acc + 1)
    after
      10 -> acc
    end
  end
end
