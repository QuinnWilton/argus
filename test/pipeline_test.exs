defmodule Argus.PipelineTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :tmp_dir

  describe "extract/2" do
    test "extracts every module asked for, Erlang's and Elixir's" do
      assert {:ok, facts} = Pipeline.extract([:lists, :maps, Enum])

      assert facts[:function_def] |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new() ==
               MapSet.new([":lists", ":maps", "Enum"])

      assert facts[:instruction] != []
    end

    test "marks call instructions that sit behind a branch as conditional" do
      {:ok, facts} = Argus.Pipeline.extract([Argus.Test.Fixtures.ConditionalInitServer])

      conditional = facts[:conditional_call] |> List.flatten() |> MapSet.new()

      # The GenServer.call inside `if opts[:sync]` is conditional...
      [[call_id | _]] =
        Enum.filter(facts[:remote_call], fn [_id, caller, mod, f, _a] ->
          String.ends_with?(caller, ":init/1") and mod == "GenServer" and f == "call"
        end)

      assert MapSet.member?(conditional, call_id)

      # ...and start_link's GenServer.start_link, on the only path, is not.
      [[start_id | _]] =
        Enum.filter(facts[:remote_call], fn [_id, caller, _m, f, _a] ->
          String.ends_with?(caller, ":start_link/1") and f == "start_link"
        end)

      refute MapSet.member?(conditional, start_id)
    end

    test "a beam's bytes give the facts its path gives" do
      path = to_string(:code.which(:lists))
      assert {:ok, from_path} = Pipeline.extract([path])
      assert Pipeline.extract([File.read!(path)]) == {:ok, from_path}
    end

    test "no modules is no facts, and a module or path not there is an error" do
      assert Pipeline.extract([]) == {:ok, %{}}

      assert {:error, {:not_found, :definitely_not_a_real_module}} =
               Pipeline.extract([:definitely_not_a_real_module])

      assert {:error, {:not_found, "no/such/file.beam"}} =
               Pipeline.extract(["no/such/file.beam"])
    end
  end

  describe "run/3" do
    test "writes a file per schema relation, of its rows, and leaves one there alone",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "prior_sensitive.facts"), "kept\n")
      assert {:ok, ^tmp_dir} = Pipeline.run([:lists, :maps], tmp_dir)

      # A missing input file is an error to an engine: every relation has
      # one, rows or not.
      for name <- Argus.Schema.names() do
        assert File.exists?(Path.join(tmp_dir, "#{name}.facts")), "no file for #{name}"
      end

      assert File.read!(Path.join(tmp_dir, "prior_sensitive.facts")) == "kept\n"

      # function_def has the schema's five fields; the entry label lives in
      # function_entry, split out because it is positional.
      {:ok, rows} = read_facts(Path.join(tmp_dir, "function_def.facts"))
      assert Enum.all?(rows, &(length(&1) == 5))
      assert rows |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new() == MapSet.new([":lists", ":maps"])
    end

    test "no modules is an empty directory of facts", %{tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Pipeline.run([], tmp_dir)
    end
  end

  describe "write_facts/2" do
    test "writes an in-memory fact map to a solvable directory", %{tmp_dir: tmp_dir} do
      {:ok, facts} = Pipeline.extract([:maps])

      assert :ok = Pipeline.write_facts(facts, tmp_dir)

      # Extracted relations round-trip through the TSV files.
      {:ok, rows} = read_facts(Path.join(tmp_dir, "function_def.facts"))
      assert Enum.any?(rows, fn [_func, mod | _] -> mod == ":maps" end)

      for name <- Argus.Schema.names() do
        assert File.exists?(Path.join(tmp_dir, "#{name}.facts")), "no file for #{name}"
      end
    end
  end

  describe "extract/2 imprecision tracing" do
    # MyGenServer.get_value/1 calls GenServer.call(server, :get) where
    # `server` is a parameter: resolve_callee returns "dynamic", which the
    # OTP extractor records as :genserver_callee imprecision.
    test "is off by default, on when asked, and off again in the next run" do
      extract = fn opts ->
        {:ok, facts} =
          Pipeline.extract(
            [Argus.Test.Fixtures.MyGenServer],
            [extractors: [Argus.Extractors.OTP, Argus.Extractors.ApiCalls]] ++ opts
          )

        facts[:imprecision] || []
      end

      assert extract.([]) == []
      assert extract.(trace_imprecision: false) == []

      assert Enum.any?(
               extract.(trace_imprecision: true),
               &match?(["genserver_callee", _func, "sync_call", "dynamic"], &1)
             )

      # The worker's flag is cleared after a traced run.
      assert extract.([]) == []
    end
  end

  defp read_facts(path) do
    with {:ok, body} <- File.read(path) do
      rows = for line <- String.split(body, "\n", trim: true), do: String.split(line, "\t")
      {:ok, rows}
    end
  end
end
