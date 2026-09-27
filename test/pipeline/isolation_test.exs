defmodule Argus.Pipeline.IsolationTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :tmp_dir

  defmodule Raises do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: []
    def extract(_data), do: raise("an extractor bug")
  end

  defmodule Throws do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: []
    def extract(_data), do: throw(:thrown)
  end

  defmodule Exits do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: []
    def extract(_data), do: exit(:gone)
  end

  defmodule Hangs do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: []
    def extract(%{module: Argus.Pipeline.IsolationTest.Slow}), do: Process.sleep(:infinity)
    def extract(_data), do: %{}
  end

  defmodule Works do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: [:works]
    def extract(%{module: mod}), do: %{works: [[inspect(mod)]]}
  end

  defmodule Malformed do
    @moduledoc false
    @behaviour Argus.Extractor
    def relations, do: [:malformed]
    def extract(%{module: mod}), do: %{malformed: [[inspect(mod), -1]]}
  end

  setup_all do
    beams =
      for name <- [Fast, Slow] do
        mod = Module.concat(__MODULE__, name)

        {:module, ^mod, beam, _} =
          Module.create(mod, quote(do: def(f, do: :ok)), Macro.Env.location(__ENV__))

        beam
      end

    %{beams: beams}
  end

  describe "an extractor that fails" do
    # The workers are linked to the caller: a raise that escaped one used
    # to exit the caller before the stream could report anything.
    for {extractor, expected} <- [
          {Raises, "an extractor bug"},
          {Throws, ":thrown"},
          {Exits, ":gone"}
        ] do
      test "#{inspect(extractor)} costs its own rows and is recorded", %{beams: [fast | _]} do
        extractor = unquote(extractor)

        assert {:ok, facts} = Pipeline.extract([fast], extractors: [extractor, Works])

        # The bytecode facts and every other extractor's rows stand.
        assert [_ | _] = facts[:function_def]
        assert facts[:works] == [["Argus.Pipeline.IsolationTest.Fast"]]

        assert [["Argus.Pipeline.IsolationTest.Fast", step, reason]] = facts[:extraction_error]
        assert step == inspect(extractor)
        assert reason =~ unquote(expected)
        refute reason =~ "\n"
      end
    end
  end

  describe "a module that outlives the timeout" do
    test "loses its facts alone, and the run goes on", %{beams: [fast, slow]} do
      assert {:ok, facts} = Pipeline.extract([fast, slow], extractors: [Hangs], timeout: 300)

      mods = for [_, mod | _] <- facts[:function_def], uniq: true, do: mod
      assert mods == ["Argus.Pipeline.IsolationTest.Fast"]

      assert [["Argus.Pipeline.IsolationTest.Slow", "pipeline", reason]] =
               facts[:extraction_error]

      assert reason =~ "300 ms"
    end

    test "is recorded in interned facts too", %{beams: [_fast, slow]} do
      symbols = Argus.Symbols.new()

      assert {:ok, facts} =
               Pipeline.extract([slow],
                 extractors: [Hangs],
                 timeout: 300,
                 format: :interned,
                 symbols: symbols
               )

      assert %{extraction_error: [[_, "pipeline", _]]} = Argus.Facts.materialize(facts, symbols)
    end
  end

  describe "an extractor whose row holds a non-string" do
    # The writer met the value and failed the whole module, recorded as
    # the base's failure: a store kept that under the base's key, which
    # holds none of the extractor's code, and served the lost module
    # after the extractor was fixed.
    test "costs its own rows, in its own step", %{beams: [fast | _], tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Pipeline.run([fast], tmp_dir, extractors: [Malformed, Works])

      read = fn name ->
        tmp_dir |> Path.join("#{name}.facts") |> File.read!() |> Argus.Tsv.decode()
      end

      assert [_ | _] = read.("function_def")
      assert read.("works") == [["Argus.Pipeline.IsolationTest.Fast"]]
      assert [["Argus.Pipeline.IsolationTest.Fast", step, reason]] = read.("extraction_error")
      assert step == inspect(Malformed)
      assert reason =~ "non-string"
    end
  end

  describe "run/3" do
    test "writes the errors beside the facts", %{beams: [fast | _], tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Pipeline.run([fast], tmp_dir, extractors: [Raises])

      rows = tmp_dir |> Path.join("extraction_error.facts") |> File.read!() |> Argus.Tsv.decode()
      assert [["Argus.Pipeline.IsolationTest.Fast", step, _reason]] = rows
      assert step == inspect(Raises)
    end
  end
end
