defmodule Argus.Graph.SemanticTest do
  @moduledoc """
  `module_semantic_facts` is the early-cutoff seam: a digest of what a
  module contributes to the program's relations, equal across edits that
  move only lines or the vsn checksum.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Graph

  @moduletag :tmp_dir

  # One Erlang module, compiled from forms so the vsn attribute and the
  # line numbers are ours to choose.
  defp beam!(dir, vsn, line) do
    forms = [
      {:attribute, 1, :module, :scry_semantic_probe},
      {:attribute, 1, :vsn, vsn},
      {:attribute, 1, :export, [{:f, 1}]},
      {:function, line, :f, 1,
       [
         {:clause, line, [{:var, line, :X}], [],
          [{:op, line, :+, {:var, line, :X}, {:integer, line, 1}}]}
       ]}
    ]

    {:ok, :scry_semantic_probe, beam} = :compile.forms(forms, [:debug_info])
    File.mkdir_p!(dir)
    path = Path.join(dir, "scry_semantic_probe.beam")
    File.write!(path, beam)
    %{scry_semantic_probe: path}
  end

  defp semantic(dir, vsn, line) do
    db = Graph.new_db(beam!(dir, vsn, line))
    Argus.Graph.module_semantic_facts(db, :scry_semantic_probe)
  end

  test "a digest, equal across a line shift and a vsn change", %{tmp_dir: dir} do
    assert {:ok, <<_::128>> = digest} = semantic(Path.join(dir, "a"), [1], 3)
    assert semantic(Path.join(dir, "b"), [1], 30) == {:ok, digest}
    assert semantic(Path.join(dir, "c"), [2], 3) == {:ok, digest}
  end
end
