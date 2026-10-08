defmodule Argus.Graph.Solve do
  @moduledoc """
  The solves: the two shared stages, and one per analysis.

    * `stage({program, :stage0})` — the call graph (`priv/dl/stage0.dl`),
      derived once for every analysis that reads it.
    * `stage({program, :points_to})` — process points-to, the exact
      program or, when it outgrows its budget, the bounded one
      (`Argus.Stages`), over stage 0's call graph.
    * `stage_output({program, stage, file})` — the digest of one file a
      stage wrote: the second and third cutoff seams. An edit that moves
      instructions but no call leaves the call graph byte-identical, and
      one that moves no process leaves points-to so; every solve reading
      only those outputs is then valid without running.
    * `analysis_inputs({program, analysis})` — the digest of each file
      the analysis's program reads: a stage's output from the stage (and
      only the stages it reads are demanded: an analysis that reads
      neither never waits for one, nor degrades with it), any other
      relation from `relation` (`Argus.Graph.Relations`).
    * `solve({program, analysis})` — the analysis's outputs, each file
      by its digest in the blob store: one `Argus.FlowLog.Solve`, keyed
      by the program's digest and its inputs', and committed (on a
      miss) to the engine this database keeps for the program and the
      analysis, which takes only the inputs whose digests moved. The
      engines stop when the database does (`Roux.Database.shutdown/1`,
      or the exit of the process that opened it).

  A solve that fails — the engine's error or timeout, a stage it reads
  failing, an output the engine did not write — is a value, `{:error,
  reason}`, and a transient one: it is not kept in a manifest, and
  neither is anything that read it, so the next run solves again. A
  failed call graph degrades every analysis with the stage's reason, a
  failed points-to stage the analyses reading it with
  `{:points_to, reason}` (`Argus.Findings.Degradation`).
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.FlowLog.Solve
  alias Argus.Graph.{Programs, Relations}
  alias Argus.Stages
  alias Roux.Blob
  alias Roux.Runtime

  @stage0_files MapSet.new(Argus.Analysis.stage0_relations(), &(&1 <> ".facts"))
  @points_to_files MapSet.new(Argus.Analysis.points_to_relations(), &(&1 <> ".facts"))

  defquery :stage, key: {program, stage}, store: :blob, transient: &match?({:error, _}, &1) do
    case stage do
      :stage0 ->
        with {:ok, outputs} <- solve_program(db, program, :stage0) do
          {:ok, %{outputs: outputs, mode: nil}}
        end

      :points_to ->
        points_to(db, program)
    end
  end

  # The exact program, then the bounded one over the same facts when the
  # exact fixpoint outgrew its budget; the stage is the last one's.
  defp points_to(db, program) do
    {:ok, exact} = Programs.rules_path(:points_to)
    {:ok, bounded} = Programs.rules_path(:points_to_bounded)
    programs = %{exact => :points_to, bounded => :points_to_bounded}

    solve = fn rules_path, _previous ->
      with {:ok, outputs} <- solve_program(db, program, Map.fetch!(programs, rules_path)),
           {:ok, results} <-
             read_outputs(db, outputs, ["points_to_overflow.csv", "pervasive.csv"]) do
        {:ok, results, outputs}
      end
    end

    case Stages.points_to(solve, nil, exact, bounded) do
      {:ok, outputs, mode} -> {:ok, %{outputs: outputs, mode: mode}}
      {:error, reason, _outputs} -> Stages.failed(reason)
    end
  end

  defquery :stage_output, key: {program, stage, file} do
    case Runtime.query(db, :stage, {program, stage}) do
      {:ok, %{outputs: %{^file => digest}}} -> {:ok, digest}
      {:ok, _} -> {:error, {:missing_output, file}}
      {:error, _} = error -> error
    end
  end

  defquery :analysis_inputs, key: {program, analysis} do
    with {:ok, io} <- Runtime.query(db, :program_io, analysis) do
      inputs(db, program, io.inputs)
    end
  end

  # Where one input file of an analysis comes from, by its digest.
  defp input(db, program, relation, file) do
    cond do
      MapSet.member?(@stage0_files, file) ->
        case Runtime.query(db, :stage_output, {program, :stage0, file}) do
          {:ok, digest} -> {:ok, {:cas, digest}}
          # Every analysis degrades with the call graph's own reason.
          {:error, reason} -> {:error, reason}
        end

      MapSet.member?(@points_to_files, file) ->
        case Runtime.query(db, :stage_output, {program, :points_to, file}) do
          {:ok, digest} -> {:ok, {:cas, digest}}
          {:error, {:points_to, _}} = error -> error
          {:error, reason} -> {:error, {:points_to, reason}}
        end

      true ->
        relation_input(db, program, relation)
    end
  end

  # A relation of the program's facts. One no argus module names holds
  # no fact, and is empty; an in-process one is extracted for the
  # program that reads it (`Argus.Graph.Relations`).
  defp relation_input(db, program, name) do
    case existing_atom(name) do
      nil -> {:ok, {:relation, name, "empty"}}
      relation -> {:ok, {:relation, relation, Runtime.query(db, :relation, {program, relation})}}
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defquery :solve, key: {program, analysis}, store: :blob, transient: &match?({:error, _}, &1) do
    with {:ok, digest} <- Runtime.query(db, :program_digest, analysis),
         {:ok, io} <- Runtime.query(db, :program_io, analysis),
         {:ok, inputs} <- Runtime.query(db, :analysis_inputs, {program, analysis}) do
      run(db, program, analysis, digest, io, inputs)
    end
  end

  # A stage's program solved over the program's relations and, for the
  # points-to stage, stage 0's call graph.
  defp solve_program(db, program, stage_program) do
    with {:ok, digest} <- Runtime.query(db, :program_digest, stage_program),
         {:ok, io} <- Runtime.query(db, :program_io, stage_program),
         {:ok, inputs} <- inputs(db, program, io.inputs) do
      run(db, program, stage_program, digest, io, inputs)
    end
  end

  # Analyses and stages resolve the same input sources and stop at the first
  # missing relation. Sort both so their solve keys are deterministic.
  defp inputs(db, program, inputs) do
    Enum.reduce_while(inputs, {:ok, []}, fn {relation, file}, {:ok, acc} ->
      case input(db, program, relation, file) do
        {:ok, source} -> {:cont, {:ok, [{relation, file, source} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.sort(inputs)}
      error -> error
    end
  end

  # How long a commit may run and how many workers an engine has decide
  # no output: the program's digest carries the toolchain's, which does.
  # Read without an edge, so a timeout raised solves nothing again.
  defp run(db, program, rules_program, digest, io, inputs) do
    {:ok, solver} = Runtime.untracked(fn -> Programs.solver(db) end)
    {:ok, path} = Programs.rules_path(rules_program)
    key = {digest, Enum.map(inputs, fn {_name, file, source} -> {file, identity(source)} end)}
    outputs = io.outputs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    engine = fn ->
      with {:ok, built} <- Argus.FlowLog.engine(path) do
        if built.digest != digest do
          {:error, {:flowlog_stale_engine, built.executable, digest, built.digest}}
        else
          {:ok,
           %{
             lineage: {program, rules_program},
             owner: db.supervisor,
             start: [
               executable: built.executable,
               args: built.args,
               digest: digest,
               workers: Map.get(solver, :workers, :auto),
               log: Argus.FlowLog.Toolchain.run_log(built.toolchain, digest)
             ]
           }}
        end
      end
    end

    result =
      Solve.run(db.blob, key, fn -> placed(db, program, inputs) end, outputs, engine,
        timeout: Map.get(solver, :timeout, Argus.FlowLog.default_timeout())
      )

    with {:ok, written} <- result do
      Runtime.hold(Map.values(written))
      {:ok, written}
    end
  end

  defp identity({:cas, digest}), do: {:cas, digest}
  defp identity({:relation, _relation, digest}), do: {:relation, digest}

  # Each input as the engine reads it, by relation name with the
  # identity its content goes by: a stage's output by its entry, and
  # every relation of the program's facts assembled (or remembered) in
  # one pass.
  defp placed(db, program, inputs) do
    relations =
      for {_name, _file, {:relation, relation, digest}} <- inputs,
          is_atom(relation),
          do: {relation, digest}

    with {:ok, files} <- Relations.files(db, program, relations) do
      {:ok,
       Enum.map(inputs, fn
         {name, file, {:cas, digest} = source} ->
           :ok = present!(db, program, file, digest)
           {name, source, identity(source)}

         {name, _file, {:relation, relation, _digest} = source} when is_atom(relation) ->
           {name, {:cas, Map.fetch!(files, relation)}, identity(source)}

         {name, _file, {:relation, _unknown, _digest} = source} ->
           {name, {:fill, &File.write(&1, "")}, identity(source)}
       end)}
    end
  end

  # A stage's output a solve links, in the store: an entry that vanished
  # (another store than the one the stage ran in, a collection) is
  # derived again by reading the stage, whose value is then missing too
  # and computed again — solved again, as its solve's outputs are no
  # longer kept — with the same digests.
  defp present!(db, program, file, digest) do
    store = db.blob

    unless Blob.member?(store, digest) do
      stage = if MapSet.member?(@stage0_files, file), do: :stage0, else: :points_to
      _ = Runtime.untracked(fn -> Runtime.query(db, :stage, {program, stage}) end)

      unless Blob.member?(store, digest) do
        raise Blob.MissingError, store: store.root, digest: digest
      end
    end

    :ok
  end

  @doc """
  The rows of a solve's outputs, by relation name (each file's name
  without its extension), for the files named: what the stage's policy
  and the findings read back.
  """
  @spec read_outputs(Roux.Database.t(), %{String.t() => String.t()}, [String.t()] | :csv) ::
          {:ok, %{String.t() => [[String.t()]]}} | {:error, term()}
  def read_outputs(db, outputs, which) do
    files =
      case which do
        :csv -> for {file, _} <- outputs, Path.extname(file) == ".csv", do: file
        files -> Enum.filter(files, &Map.has_key?(outputs, &1))
      end

    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case Solve.rows(db.blob, file, Map.fetch!(outputs, file)) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, Path.rootname(file), rows)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
