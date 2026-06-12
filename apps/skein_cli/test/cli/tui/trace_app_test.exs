defmodule Skein.CLI.Tui.TraceAppTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Tui.TraceApp

  defp result(spans), do: %{spans: spans, count: length(spans)}

  defp spans(n) do
    for i <- 1..n do
      %{kind: :http, method: :get, url: "/item/#{i}", outcome: :ok, duration_us: i * 100}
    end
  end

  describe "new_model/1" do
    test "starts with the first span selected" do
      model = TraceApp.new_model(result(spans(3)))
      assert model.selected == 0
      assert model.count == 3
      assert length(model.spans) == 3
    end

    test "handles an empty result" do
      model = TraceApp.new_model(result([]))
      assert model.spans == []
      assert model.count == 0
      assert model.selected == 0
    end
  end

  describe "select/2" do
    test "moves the selection down and up" do
      model = TraceApp.new_model(result(spans(3)))

      model = TraceApp.select(model, 1)
      assert model.selected == 1

      model = TraceApp.select(model, -1)
      assert model.selected == 0
    end

    test "clamps at both ends" do
      model = TraceApp.new_model(result(spans(2)))

      assert TraceApp.select(model, -1).selected == 0
      assert TraceApp.select(TraceApp.select(model, 5), 1).selected == 1
    end

    test "is a no-op on an empty span list" do
      model = TraceApp.new_model(result([]))
      assert TraceApp.select(model, 1).selected == 0
      assert TraceApp.select(model, -1).selected == 0
    end
  end

  describe "init/1" do
    test "reads the trace result from the runtime options" do
      context = %{width: 80, height: 24, options: [trace_result: result(spans(2))]}
      model = TraceApp.init(context)
      assert model.count == 2
    end

    test "defaults to an empty model without options" do
      assert TraceApp.init(%{width: 80, height: 24, options: []}).count == 0
    end
  end

  describe "view/1" do
    test "renders without raising for populated and empty models" do
      assert TraceApp.view(TraceApp.new_model(result(spans(3)))) != nil
      assert TraceApp.view(TraceApp.new_model(result([]))) != nil
    end
  end
end
