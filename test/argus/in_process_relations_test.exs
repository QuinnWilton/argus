defmodule Argus.InProcessRelationsTest do
  use ExUnit.Case, async: true

  alias Argus.{Analysis, Schema, Souffle}

  @moduledoc """
  `Argus.Schema.in_process_only/0` names the relations
  `Argus.Analysis.extract_facts/3` leaves out of the directory it stages.
  That is only sound while no Souffle program reads them, which this test
  asks Souffle itself (the pruned RAM is the oracle, as in
  `Argus.DlDeclarationsTest`).
  """

  test "no built-in program reads an in-process-only relation" do
    skip_without_souffle()

    programs = [
      Analysis.stage0_rules_path()
      | Enum.map(Analysis.builtin_analysis_modules(), &rules_path/1)
    ]

    in_process = MapSet.new(Schema.in_process_only(), &to_string/1)

    for program <- programs do
      assert {:ok, inputs} = Souffle.input_relations(program)
      read = inputs |> MapSet.new() |> MapSet.intersection(in_process) |> Enum.sort()

      assert read == [],
             "#{Path.basename(program)} reads #{inspect(read)}; drop them from " <>
               "Argus.Schema.in_process_only/0 or stop reading them"
    end
  end

  test "every in-process-only relation is a layer-1 relation" do
    layer_1 = Schema.layer_1() |> Enum.map(& &1.name) |> MapSet.new()

    for name <- Schema.in_process_only() do
      assert MapSet.member?(layer_1, name), "#{name} is not a layer-1 relation"
    end
  end

  defp rules_path(mod), do: Application.app_dir(:panoptes, Path.join("priv/dl", mod.rules_file()))

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end
end
