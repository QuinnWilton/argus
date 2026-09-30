defmodule Argus.RunTest do
  use ExUnit.Case, async: true

  doctest Argus.Run
end

defmodule Argus.RunFactsTest do
  @moduledoc """
  `Argus.Analysis.extract_facts/3` writes, in every file of a relation
  the producers extract, the rows `Argus.Pipeline.extract/2` gives for
  the producers the analyses run (the base, the call-argument extractor
  and each analysis's own): `line_info` among them, the imprecision
  trace only for `:coverage`. Relations are sets. Label numbers are
  compared by their target instruction, since function queries use local labels.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Pipeline.{Disassemble, Function, Normalize}
  alias Argus.Test.Fixtures.PidFlow

  @modules [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server] ++
             for(
               name <- ~w(SafeCall UserA UserB TargetA TargetB),
               do: Module.concat(PidFlow, name)
             )

  defp file_rows(dir, relation) do
    case File.read(Path.join(dir, "#{relation}.facts")) do
      {:ok, content} -> content |> Argus.Tsv.decode() |> Enum.sort()
      {:error, reason} -> flunk("#{relation}.facts: #{inspect(reason)}")
    end
  end

  defp extractors(analyses) do
    for(
      {:ok, module} <- Enum.map(analyses, &Analysis.fetch_module/1),
      e <- module.extractors(),
      do: e
    )
    |> then(&Enum.uniq([Argus.Extractors.CallArgs | &1]))
  end

  defp label_targets do
    {:ok, paths} = Disassemble.resolve_paths(@modules)

    for path <- paths,
        {:ok, data} = Disassemble.disassemble_path(path),
        {:function, name, arity, _, instructions} = function <- data.functions,
        into: %{} do
      {{:function, _, _, _, canonical}, _} =
        Function.canonical(function, data.line_table, Function.entries(data))

      {Normalize.func_id(data.module, name, arity),
       %{pipeline: targets(instructions), graph: targets(canonical)}}
    end
  end

  defp targets(instructions) do
    for {{:label, label}, index} <- Enum.with_index(instructions),
        into: %{"0" => "0"},
        do: {to_string(label), "instruction #{index}"}
  end

  defp rows(rows, relation, targets, source) do
    rows
    |> Enum.map(fn row ->
      if relation in [:bif_call, :recv_start, :try_start] do
        labels = targets |> Map.fetch!(Enum.at(row, 1)) |> Map.fetch!(source)
        List.update_at(row, -1, &Map.fetch!(labels, &1))
      else
        row
      end
    end)
    |> MapSet.new()
  end

  for analyses <- [[:startup, :races], [:coverage], [:mailbox, :ets, :effects]] do
    test "for #{inspect(analyses)}, every file holds the pipeline's rows" do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")
      analyses = unquote(analyses)

      {:ok, dir} = Analysis.extract_facts(@modules, analyses)

      {:ok, facts} =
        Argus.Pipeline.extract(@modules,
          extractors: extractors(analyses),
          trace_imprecision: :coverage in analyses
        )

      try do
        targets = label_targets()
        derived = Analysis.stage0_relations() ++ Analysis.points_to_relations()

        differing =
          for relation <- Argus.Schema.names() -- Argus.Schema.in_process_only(),
              Atom.to_string(relation) not in derived,
              expected = rows(Map.get(facts, relation, []), relation, targets, :pipeline),
              rows(file_rows(dir, relation), relation, targets, :graph) != expected,
              do: relation

        assert differing == []
        assert file_rows(dir, :line_info) != []
        assert file_rows(dir, :imprecision) != [] == :coverage in analyses
      after
        File.rm_rf!(Path.dirname(dir))
      end
    end
  end
end
