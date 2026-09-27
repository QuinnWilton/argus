defmodule Argus.Graph.SemanticTest do
  @moduledoc """
  `module_semantic` is the early-cutoff seam: what a module contributes
  to the program's relations, equal across edits that move only lines
  or the vsn checksum.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Graph

  @moduletag :tmp_dir

  # One Erlang module, compiled from forms so the vsn attribute and the
  # line numbers are ours to choose.
  defp beam!(dir, vsn, line) do
    forms = [
      {:attribute, 1, :module, :argus_semantic_probe},
      {:attribute, 1, :vsn, vsn},
      {:attribute, 1, :export, [{:f, 1}]},
      {:function, line, :f, 1,
       [
         {:clause, line, [{:var, line, :X}], [],
          [{:op, line, :+, {:var, line, :X}, {:integer, line, 1}}]}
       ]}
    ]

    {:ok, :argus_semantic_probe, beam} = :compile.forms(forms, [:debug_info])
    File.mkdir_p!(dir)
    path = Path.join(dir, "argus_semantic_probe.beam")
    File.write!(path, beam)
    {path, %{argus_semantic_probe: path}}
  end

  defp semantic(dir, vsn, line) do
    {path, paths} = beam!(dir, vsn, line)
    db = Graph.new_db(paths)

    {Argus.Graph.Extraction.module_semantic(db, path),
     Argus.Graph.Extraction.module_facts(db, path)}
  end

  test "equal across a line shift and a vsn change; the facts are not", %{tmp_dir: dir} do
    assert {{:ok, semantic}, {:ok, facts}} = semantic(Path.join(dir, "a"), [1], 3)
    refute Map.has_key?(semantic, :line_info)
    assert Map.has_key?(facts.relations, :line_info)

    assert {{:ok, ^semantic}, {:ok, shifted}} = semantic(Path.join(dir, "b"), [1], 30)
    refute shifted.relations == facts.relations
    assert {{:ok, ^semantic}, {:ok, _}} = semantic(Path.join(dir, "c"), [2], 3)
  end
end
