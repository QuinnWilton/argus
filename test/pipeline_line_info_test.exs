defmodule Argus.PipelineLineInfoTest do
  # Sync: compiling the probe sets the VM-wide :debug_info compiler
  # option, which every other test that compiles code would see.
  use ExUnit.Case, async: false

  alias Argus.Pipeline

  @moduletag :tmp_dir

  describe "extract/2" do
    test "line_info carries real source lines, not Line-chunk references",
         %{tmp_dir: tmp_dir} do
      source = """
      defmodule ArgusLineInfoProbe do
        def run(a, b) do
          x = a + b
          y = x * 2
          {x, y}
        end
      end
      """

      previous = Code.get_compiler_option(:debug_info)
      Code.put_compiler_option(:debug_info, true)

      [{mod, beam} | _] =
        try do
          Code.compile_string(source, "nofile")
        after
          Code.put_compiler_option(:debug_info, previous)
        end

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
      end)

      path = Path.join(tmp_dir, "#{mod}.beam")
      File.write!(path, beam)

      {:ok, facts} = Pipeline.extract([path], format: :typed)
      lines = facts[:line_info] |> Enum.map(& &1.line) |> Enum.uniq() |> Enum.sort()

      # Exactly the marker-bearing source lines: the head (2), `x = a + b`
      # (3), and `y = x * 2` (4). Under reference semantics this set would
      # have started at 1 (and 0 markers on generated functions would have
      # produced rows); under line semantics the generated functions emit
      # nothing.
      assert lines == [2, 3, 4]
    end
  end
end
