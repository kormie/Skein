defmodule Skein.Runtime.SchedulePropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime schedule dispatch module.

  Tests cron parsing across generated expressions, registration, and
  triggering with varied handler payloads.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Schedule

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp minute_gen do
    StreamData.one_of([
      StreamData.constant("*"),
      StreamData.map(StreamData.integer(0..59), &Integer.to_string/1),
      StreamData.map(StreamData.integer(1..30), &"*/#{&1}")
    ])
  end

  defp hour_gen do
    StreamData.one_of([
      StreamData.constant("*"),
      StreamData.map(StreamData.integer(0..23), &Integer.to_string/1),
      StreamData.map(StreamData.integer(1..12), &"*/#{&1}")
    ])
  end

  defp day_gen do
    StreamData.one_of([
      StreamData.constant("*"),
      StreamData.map(StreamData.integer(1..31), &Integer.to_string/1)
    ])
  end

  defp month_gen do
    StreamData.one_of([
      StreamData.constant("*"),
      StreamData.map(StreamData.integer(1..12), &Integer.to_string/1)
    ])
  end

  defp weekday_gen do
    StreamData.one_of([
      StreamData.constant("*"),
      StreamData.map(StreamData.integer(0..6), &Integer.to_string/1)
    ])
  end

  defp cron_gen do
    gen all(
          minute <- minute_gen(),
          hour <- hour_gen(),
          day <- day_gen(),
          month <- month_gen(),
          weekday <- weekday_gen()
        ) do
      "#{minute} #{hour} #{day} #{month} #{weekday}"
    end
  end

  defp invalid_cron_gen do
    StreamData.one_of([
      StreamData.constant(""),
      StreamData.constant("* *"),
      StreamData.constant("* * *"),
      StreamData.constant("only-one-field"),
      gen all(
            fields <-
              StreamData.list_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 3),
                min_length: 6,
                max_length: 10
              )
          ) do
        Enum.join(fields, " ")
      end
    ])
  end

  setup do
    on_exit(fn -> Schedule.reset_all() end)
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "parse_cron succeeds for any valid 5-field expression" do
    check all(cron <- cron_gen()) do
      assert {:ok, parsed} = Schedule.parse_cron(cron)
      assert Map.has_key?(parsed, :minute)
      assert Map.has_key?(parsed, :hour)
      assert Map.has_key?(parsed, :day)
      assert Map.has_key?(parsed, :month)
      assert Map.has_key?(parsed, :weekday)
    end
  end

  property "parse_cron round-trips field values" do
    check all(
            minute <- minute_gen(),
            hour <- hour_gen(),
            day <- day_gen(),
            month <- month_gen(),
            weekday <- weekday_gen()
          ) do
      cron = "#{minute} #{hour} #{day} #{month} #{weekday}"
      assert {:ok, parsed} = Schedule.parse_cron(cron)
      assert parsed.minute == minute
      assert parsed.hour == hour
      assert parsed.day == day
      assert parsed.month == month
      assert parsed.weekday == weekday
    end
  end

  property "parse_cron rejects expressions without exactly 5 fields" do
    check all(cron <- invalid_cron_gen()) do
      assert {:error, _} = Schedule.parse_cron(cron)
    end
  end

  property "registering a handler adds cron to list_schedules" do
    check all(cron <- cron_gen()) do
      Schedule.reset_all()
      Schedule.register_fn(cron, fn _ -> :ok end)
      assert cron in Schedule.list_schedules()
    end
  end

  property "trigger calls the registered handler" do
    check all(cron <- cron_gen()) do
      Schedule.reset_all()
      test_pid = self()

      Schedule.register_fn(cron, fn _ctx ->
        send(test_pid, {:triggered, cron})
        :ok
      end)

      Schedule.trigger(cron)
      assert_receive {:triggered, ^cron}, 1000
    end
  end

  property "trigger on unregistered cron does not crash" do
    check all(cron <- cron_gen()) do
      Schedule.reset_all()
      assert :ok = Schedule.trigger(cron)
    end
  end

  property "reset_all clears all registrations" do
    check all(
            crons <-
              StreamData.uniq_list_of(cron_gen(), min_length: 1, max_length: 5)
          ) do
      Schedule.reset_all()

      for cron <- crons do
        Schedule.register_fn(cron, fn _ -> :ok end)
      end

      Schedule.reset_all()
      assert Schedule.list_schedules() == []
    end
  end
end
