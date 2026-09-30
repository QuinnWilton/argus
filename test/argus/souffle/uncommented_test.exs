defmodule Argus.Souffle.UncommentedTest do
  @moduledoc """
  Comment-only edits preserve every shipped program's cache key and compiled
  instructions. Comparing the full RAM program covers every input dataset;
  only diagnostic source locations may change.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Souffle.Program

  doctest Argus.Souffle.Program, only: [uncommented: 1]

  @moduletag :tmp_dir

  test "a comment line that opens or closes a block comment is kept" do
    for text <- ["a(1).\n// opens /*\nb(2).", "a(1).\n// closes */\nb(2)."] do
      assert Program.uncommented(text) == Enum.join(String.split(text, "\n"), "\n")
    end
  end

  test "a comment after code on its line is code's" do
    assert Program.uncommented("a(1). // why\n") == "a(1). // why"
  end

  @tag timeout: 120_000
  test "prose preserves every program's key and compiled instructions; a rule edit does", %{
    tmp_dir: tmp
  } do
    unless Souffle.available?(), do: flunk("souffle not installed")
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
        assert compiled(program) == compiled(original), program
        :ok
      end,
      max_concurrency: 4,
      timeout: 120_000
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    races = Path.join(dl, "analyses/races.dl")
    original = compiled(races)

    File.write!(
      races,
      File.read!(races) <>
        "\n.decl argus_probe(x: symbol)\n.output argus_probe\nargus_probe(\"changed\").\n"
    )

    refute Program.declared_digest(races, :all) == before[races]
    refute compiled(races) == original
  end

  defp compiled(program) do
    {ram, status} =
      System.cmd(Souffle.executable(), ["--wno=all", "--show=transformed-ram", program],
        stderr_to_stdout: true
      )

    assert status == 0, "#{program} failed to compile:\n#{ram}"

    # Keep the complete instructions and debug rule text; ignore only source ranges.
    Regex.replace(
      ~r/^([ \t]*DEBUG ".*\\nin file [^"\n]+ )\[\d+:\d+-\d+:\d+\]"$/m,
      ram,
      "\\1[location]\""
    )
  end
end
