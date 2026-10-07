defmodule Argus.Dl.UncommentedTest do
  @moduledoc """
  Comment-only edits preserve every shipped program's cache key and the
  dataflow FlowLog compiles it to. Compare the engine module the tool
  generates (`argus-flowlog-tool generate`), which covers declarations,
  components and every rule, independently of any input dataset.
  """
  use ExUnit.Case, async: true

  alias Argus.Dl.Program

  doctest Argus.Dl.Program, only: [uncommented: 1]

  @moduletag :tmp_dir

  test "a comment line that opens or closes a block comment is kept" do
    for text <- ["a(1).\n// opens /*\nb(2).", "a(1).\n// closes */\nb(2)."] do
      assert Program.uncommented(text) == Enum.join(String.split(text, "\n"), "\n")
    end
  end

  test "a comment after code on its line is code's" do
    assert Program.uncommented("a(1). // why\n") == "a(1). // why"
  end

  @tag :flowlog
  @tag timeout: 120_000
  test "prose preserves every program's key and parsed rules; a rule edit does", %{
    tmp_dir: tmp
  } do
    shipped = Argus.Dl.root()
    dl = Path.join(tmp, "dl")
    File.cp_r!(shipped, dl)

    programs =
      Path.wildcard(Path.join(dl, "analyses/*.dl")) ++
        Enum.map(~w(stage0.dl points_to.dl points_to_bounded.dl), &Path.join(dl, &1))

    before = Map.new(programs, &{&1, Program.declared_digest(&1, :all)})

    for file <- Path.wildcard(Path.join(dl, "**/*.dl")),
        content = File.read!(file),
        Program.declarations(content) == :error do
      prose = content |> String.split("\n") |> Enum.map_join("\n", &(&1 <> "\n  // prose"))
      File.write!(file, "// a header\n\n" <> prose <> "\n// a footer\n")
    end

    programs
    |> Task.async_stream(
      fn program ->
        original = Path.join(shipped, Path.relative_to(program, dl))
        assert Program.declared_digest(program, :all) == before[program], program
        assert parsed(program) == parsed(original), program
        :ok
      end,
      max_concurrency: 4,
      timeout: 120_000
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    races = Path.join(dl, "analyses/races.dl")
    original = parsed(races)

    File.write!(
      races,
      File.read!(races) <>
        "\n.decl argus_probe(x: symbol)\n.output argus_probe\nargus_probe(\"changed\").\n"
    )

    refute Program.declared_digest(races, :all) == before[races]
    refute parsed(races) == original
  end

  # The engine module FlowLog generates for the program: what it would
  # build, rule for rule.
  defp parsed(program) do
    {:ok, toolchain} = Argus.FlowLog.toolchain(progress: false)
    out = Path.join(System.tmp_dir!(), "argus_parsed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(out)

    try do
      {output, status} =
        System.cmd(Argus.FlowLog.Toolchain.tool(toolchain), ["generate", program, out, "digest"])

      assert status == 0, "#{program} failed to compile:\n#{output}"
      File.read!(Path.join(out, "program.rs"))
    after
      File.rm_rf!(out)
    end
  end
end
