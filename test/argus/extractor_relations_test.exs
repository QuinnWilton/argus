defmodule Argus.ExtractorRelationsTest do
  @moduledoc """
  Every extractor declares the relations it emits, and every one of them
  exists in the schema and is read by a rule. Twelve relations had
  accumulated that no rule read — extracted on every run, versioned,
  digested — before anything asked this question.
  """

  use ExUnit.Case, async: true

  alias Argus.{Analysis, Schema}

  defp extractors do
    Analysis.builtin_analysis_modules()
    |> Enum.flat_map(& &1.extractors())
    |> Enum.uniq()
  end

  defp source(extractor) do
    extractor
    |> Module.split()
    |> Enum.map_join("/", &Macro.underscore/1)
    |> then(&File.read!("lib/#{&1}.ex"))
  end

  # A table-driven extractor names its relation through a variable, so
  # no literal appears at the call site.
  @table_driven %{Argus.Extractors.EctoSchema => [:schema_field, :redacted_field]}

  defp emitted_in_source(extractor) do
    ~r/add_fact\(\s*(?:[^,:()]+,\s*)*:([a-z_0-9]+)/
    |> Regex.scan(source(extractor))
    |> MapSet.new(fn [_, name] -> String.to_atom(name) end)
    |> MapSet.union(MapSet.new(Map.get(@table_driven, extractor, [])))
  end

  defp rules_source do
    ["priv/dl/stage0.dl" | Path.wildcard("priv/dl/{analyses,clientlib}/*.dl")]
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "every declared relation is in the schema" do
    names = MapSet.new(Schema.names())

    for extractor <- extractors(), relation <- extractor.relations() do
      assert MapSet.member?(names, relation),
             "#{inspect(extractor)} declares #{relation}, which Argus.Schema does not define"
    end
  end

  test "every declared relation is read by some rule" do
    rules = rules_source()

    unread =
      for extractor <- extractors(),
          relation <- extractor.relations(),
          not Regex.match?(~r/(?<![\w.])#{relation}\(/, rules),
          do: {extractor, relation}

    assert unread == [],
           "extracted on every run and read by nothing:\n" <>
             Enum.map_join(unread, "\n", fn {e, r} -> "  #{inspect(e)} -> #{r}" end)
  end

  test "the declaration matches what the source emits" do
    for extractor <- extractors() do
      declared = MapSet.new(extractor.relations())
      emitted = emitted_in_source(extractor)

      assert MapSet.equal?(declared, emitted),
             "#{inspect(extractor)}: declared #{inspect(MapSet.to_list(declared))}, " <>
               "source emits #{inspect(MapSet.to_list(emitted))}"
    end
  end
end
