defmodule Skein.Freeze.EffectAbiFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the full effect-ABI surface.

  The structured-error ABI was declared Stable with C2/#297; this gate
  extends the freeze to the complete method surface: every effect and
  store method's signature (params, optionality, return type, capability,
  scoping), the provider contracts, and the error enums, pinned against
  `conformance/freeze/effect_abi.json`. The runtime ABI matrix
  (`effect_abi_matrix_test.exs`) pins the live shapes; the spec §6 drift
  tests (`effect_abi_test.exs`) pin the documented signatures — this
  vector pins the registry itself, so nothing can move without a
  deliberate vector update.

  New methods/variants are minors; changing or removing an existing one
  is a major. Regenerate deliberately with FREEZE_REGEN=1.
  """

  alias Skein.EffectABI

  @vector Path.expand("../../../../../conformance/freeze/effect_abi.json", __DIR__)

  defp current do
    %{
      "entries" =>
        Enum.map(EffectABI.entries(), fn e ->
          %{
            "ns" => e.ns,
            "method" => e.method,
            "capability" => e.capability,
            "scoped" => e.scoped && Atom.to_string(e.scoped),
            "params" =>
              Enum.map(e.params, fn p ->
                %{"name" => p.name, "type" => inspect(p.type), "optional" => p.optional}
              end),
            "named_args" => e.named_args,
            "return" => inspect(e.return),
            "dispatch" => Atom.to_string(e.dispatch),
            "spec_lines" => e.spec_lines
          }
        end),
      "store_entries" =>
        Enum.map(EffectABI.store_entries(), fn e ->
          %{"method" => e.method, "return" => inspect(e.return), "spec_lines" => e.spec_lines}
        end),
      "provider_contracts" =>
        Map.new(EffectABI.provider_contracts(), fn {kind, contract} ->
          {kind, %{"signature" => contract.signature}}
        end),
      "error_enums" =>
        Map.new(EffectABI.error_enums(), fn {enum, variants} ->
          {enum,
           Enum.map(variants, fn v ->
             %{
               "name" => v.name,
               "fields" =>
                 Enum.map(v.fields, fn {field, type} ->
                   %{"name" => field, "type" => inspect(type)}
                 end)
             }
           end)}
        end)
    }
  end

  test "the effect-ABI registry matches the frozen vector" do
    current = current() |> Jason.encode!() |> Jason.decode!()
    frozen = @vector |> File.read!() |> Jason.decode!() |> Map.delete("comment")

    if System.get_env("FREEZE_REGEN") == "1" do
      comment = @vector |> File.read!() |> Jason.decode!() |> Map.get("comment")

      File.write!(
        @vector,
        Jason.encode!(Map.put(current(), "comment", comment), pretty: true) <> "\n"
      )

      flunk("regenerated #{@vector} — review the diff and commit it deliberately")
    else
      assert current == frozen,
             "the effect ABI drifted from conformance/freeze/effect_abi.json — " <>
               "changing an existing method/variant is a MAJOR-level break; a " <>
               "deliberate additive change regenerates the vector (FREEZE_REGEN=1) " <>
               "in the same PR, with ports/pins/corpus moved together"
    end
  end
end
