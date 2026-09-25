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

    test "a try takes the line of the expression it protects, not the last in the listing",
         %{tmp_dir: tmp_dir} do
      source = """
      defmodule ArgusTryLineProbe do
        def parse("Bearer " <> token), do: String.trim(token)

        def parse("Basic " <> auth) do
          try do
            Base.decode64!(auth)
          rescue
            _ -> :invalid
          end
        end
      end
      """

      [{mod, beam} | _] = Code.compile_string(source, "nofile")

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
      end)

      path = Path.join(tmp_dir, "#{mod}.beam")
      File.write!(path, beam)

      {:ok, facts} = Pipeline.extract([path], format: :typed)
      line_of = Map.new(facts[:line_info], &{&1.id, &1.line})

      assert [try] = Enum.filter(facts[:instruction], &(&1.op == "try"))

      # The first clause's String.trim/1 (line 2) comes last in the
      # listing before the second clause's try; the try protects line 6.
      assert Map.fetch!(line_of, try.id) == 6
    end
  end
end
