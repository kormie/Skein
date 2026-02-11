defmodule Skein.Runtime.TimerPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Timer

  setup do
    on_exit(fn -> Timer.reset_all() end)
  end

  # Helper to call Timer.after/3 (reserved word in Elixir)
  defp timer_after(delay_ms, callback, caps) do
    apply(Timer, :after, [delay_ms, callback, caps])
  end

  property "after always returns {:ok, string_ref}" do
    check all(delay <- integer(100..1000)) do
      Timer.reset_all()
      Process.sleep(50)

      {:ok, ref} = timer_after(delay, fn -> :ok end, [])
      assert is_binary(ref)
      assert byte_size(ref) > 0
    end
  end

  property "interval always returns {:ok, string_ref}" do
    check all(interval <- integer(100..1000)) do
      Timer.reset_all()
      Process.sleep(50)

      {:ok, ref} = Timer.interval(interval, fn -> :ok end, [])
      assert is_binary(ref)
      assert byte_size(ref) > 0
    end
  end

  property "all timer refs are unique" do
    check all(count <- integer(2..10)) do
      Timer.reset_all()
      Process.sleep(50)

      refs =
        for _ <- 1..count do
          {:ok, ref} = timer_after(5000, fn -> :ok end, [])
          ref
        end

      assert length(Enum.uniq(refs)) == count
    end
  end

  property "cancel always returns :ok regardless of ref" do
    check all(ref <- string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert :ok = Timer.cancel(ref, [])
    end
  end
end
