defmodule Skein.Runtime.ScheduleTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Schedule

  setup do
    on_exit(fn -> Schedule.reset_all() end)
  end

  describe "register/3" do
    test "registers a schedule handler" do
      assert :ok = Schedule.register("*/5 * * * *", FakeModule, :__handler_0__)
    end

    test "multiple schedules can be registered" do
      assert :ok = Schedule.register("*/5 * * * *", FakeModule, :__handler_0__)
      assert :ok = Schedule.register("0 * * * *", FakeModule, :__handler_1__)
    end
  end

  describe "trigger/1" do
    test "triggers a registered schedule handler" do
      test_pid = self()

      handler_fn = fn _ctx ->
        send(test_pid, :triggered)
        {:respond_json, 200, "tick"}
      end

      Schedule.register_fn("*/5 * * * *", handler_fn)
      Schedule.trigger("*/5 * * * *")

      assert_receive :triggered, 1000
    end

    test "trigger with unregistered cron expression does nothing" do
      assert :ok = Schedule.trigger("0 0 1 1 *")
    end
  end

  describe "list_schedules/0" do
    test "returns empty list when no schedules" do
      assert Schedule.list_schedules() == []
    end

    test "returns registered cron expressions" do
      Schedule.register_fn("*/5 * * * *", fn _ -> :ok end)
      Schedule.register_fn("0 * * * *", fn _ -> :ok end)

      schedules = Schedule.list_schedules()
      assert "*/5 * * * *" in schedules
      assert "0 * * * *" in schedules
    end
  end

  describe "parse_cron/1" do
    test "parses valid 5-field cron expression" do
      assert {:ok, _} = Schedule.parse_cron("*/5 * * * *")
    end

    test "parses specific minute cron" do
      assert {:ok, %{minute: "0", hour: "*", day: "*", month: "*", weekday: "*"}} =
               Schedule.parse_cron("0 * * * *")
    end

    test "parses daily midnight cron" do
      assert {:ok, %{minute: "0", hour: "0", day: "*", month: "*", weekday: "*"}} =
               Schedule.parse_cron("0 0 * * *")
    end

    test "rejects invalid cron with too few fields" do
      assert {:error, _} = Schedule.parse_cron("* *")
    end

    test "rejects empty cron expression" do
      assert {:error, _} = Schedule.parse_cron("")
    end
  end
end
