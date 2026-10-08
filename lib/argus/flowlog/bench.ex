defmodule Argus.FlowLog.Bench do
  @moduledoc """
  What a change to an engine or a rule does to a solve: how long a
  program takes over a facts directory from scratch and after a one-row
  edit, the memory its engine peaks at and keeps, and a digest of every
  output, so that a change meant only to be faster can be seen to find
  the same rows (`mix argus.flowlog bench`).

  A program is solved `:runs` times, each in a fresh engine (the one
  `Argus.FlowLog.engine/2` chooses, as a solve would); the first run's
  engine then takes `:edits` one-row edits of the program's largest input,
  each a commit removing a row and one putting it back, timed apart. A
  measure is the fastest run's time and each edit commit's, and the
  engine's own report of its memory (`Argus.FlowLog.Engine.usage/1`):
  what it held after the solve, once it had handed freed memory back,
  and its peak.

  The facts directory holds every input the programs read: a directory
  `Argus.Analysis.extract_facts/3` writes (`mix argus.flowlog facts`), or a
  debug bundle's facts. A program whose input is not there is not
  benchmarked, and a solve a `.limitsize` stopped is measured as far as
  it got.

  Results are plain data (`t:measure/0`), kept as JSON by `write!/2` and
  compared by `compare/2`.
  """

  alias Argus.FlowLog
  alias Argus.FlowLog.Engine

  @typedoc "One program's measure."
  @type measure :: %{
          program: String.t(),
          engine: :compiled | :generic,
          workers: pos_integer(),
          outcome: String.t(),
          cold_ms: [float()],
          edit_ms: [float()],
          bytes: non_neg_integer() | nil,
          peak_bytes: non_neg_integer() | nil,
          outputs: %{String.t() => %{rows: non_neg_integer(), digest: String.t()}}
        }

  @default_timeout 3_600_000

  @doc """
  The programs of `programs` (default `Argus.FlowLog.builtin_programs/0`)
  whose every input has a file in `facts_dir`, each `{path, missing}`
  with the inputs it lacks.
  """
  @spec programs(Path.t(), [Path.t()]) :: {[Path.t()], [{Path.t(), [String.t()]}]}
  def programs(facts_dir, programs \\ FlowLog.builtin_programs()) do
    programs
    |> Enum.map(fn path ->
      {:ok, manifest} = FlowLog.manifest(path)

      missing =
        for %{name: name, file: file} <- manifest.inputs,
            not File.regular?(Path.join(facts_dir, file)),
            do: name

      {path, missing}
    end)
    |> Enum.split_with(fn {_path, missing} -> missing == [] end)
    |> then(fn {ready, lacking} -> {Enum.map(ready, &elem(&1, 0)), lacking} end)
  end

  @doc """
  Measures `program` over `facts_dir`. Options: `:runs` (default 1),
  `:edits` (default 3), `:timeout` per commit in milliseconds (default an
  hour), `:workers` (a count, or `:auto` as a solve chooses them:
  `Argus.FlowLog.workers/2`), and `:engine` as `Argus.FlowLog.engine/2`
  takes it.
  """
  @spec measure(Path.t(), Path.t(), keyword()) :: {:ok, measure()} | {:error, term()}
  def measure(facts_dir, program, opts \\ []) do
    runs = Keyword.get(opts, :runs, 1)
    edits = Keyword.get(opts, :edits, 3)

    with {:ok, built} <- FlowLog.engine(program, Keyword.take(opts, [:engine, :progress])) do
      inputs =
        Map.new(built.manifest.inputs, fn %{name: name, file: file} ->
          {name, Path.join(facts_dir, file)}
        end)

      bytes = inputs |> Map.values() |> Enum.map(&File.stat!(&1).size) |> Enum.sum()

      opts =
        Keyword.put(opts, :workers, FlowLog.workers(Keyword.get(opts, :workers, :auto), bytes))

      scratch = scratch_dir()

      try do
        first = solve(built, inputs, scratch, edits, opts)
        rest = for _ <- 2..runs//1, do: solve(built, inputs, scratch, 0, opts)
        {:ok, summarize(program, built, opts[:workers], [first | rest])}
      after
        File.rm_rf(scratch)
      end
    end
  end

  # One run in an engine of its own: the cold commit, its outputs, the
  # edits, and the engine's memory as it stood after the solve.
  defp solve(built, inputs, scratch, edits, opts) do
    case FlowLog.start_engine(built, Keyword.take(opts, [:workers])) do
      {:ok, engine} ->
        try do
          solve_in(engine, built, inputs, scratch, edits, opts)
        after
          Engine.stop(engine)
        end

      {:error, reason} ->
        failed(reason, 0)
    end
  end

  defp failed(reason, ms) do
    %{
      outcome: "failed: " <> FlowLog.describe_error(reason),
      cold_ms: ms,
      usage: nil,
      outputs: %{},
      edits: []
    }
  end

  defp solve_in(engine, built, inputs, scratch, edits, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    out = Path.join(scratch, "out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(out)

    {micros, committed} = :timer.tc(fn -> Engine.commit(engine, out, inputs, %{}, timeout) end)

    case committed do
      {:ok, _} ->
        usage = usage(engine)
        outputs = outputs(out, built.manifest)
        edit_ms = edit(engine, inputs, scratch, edits, timeout)
        %{outcome: "ok", cold_ms: micros / 1000, usage: usage, outputs: outputs, edits: edit_ms}

      {:error, {:limitsize, relation, rows, limit}} ->
        %{
          outcome: "stopped: #{relation} reached #{rows} rows of its #{limit}",
          cold_ms: micros / 1000,
          usage: usage(engine),
          outputs: %{},
          edits: []
        }

      {:error, reason} ->
        failed(reason, micros / 1000)
    end
  end

  defp usage(engine) do
    case Engine.usage(engine) do
      {:ok, usage} -> usage
      {:error, _} -> nil
    end
  end

  # Each edit removes one row of the largest input, spread through it,
  # and puts it back: two commits, each timed.
  defp edit(_engine, _inputs, _scratch, 0, _timeout), do: []

  defp edit(engine, inputs, scratch, edits, timeout) do
    {name, path} = Enum.max_by(inputs, fn {_name, path} -> File.stat!(path).size end)
    lines = path |> File.read!() |> String.split("\n", trim: true)

    if lines == [] do
      []
    else
      out = Path.join(scratch, "edits")
      File.mkdir_p!(out)
      count = length(lines)

      Enum.flat_map(1..edits, fn i ->
        at = div(i * count, edits + 1)
        without = Path.join(scratch, "#{name}-without-#{i}.facts")
        File.write!(without, Enum.map(List.delete_at(lines, at), &[&1, ?\n]))

        removed = commit_ms(engine, out, %{name => {without, path}}, timeout)
        restored = commit_ms(engine, out, %{name => {path, without}}, timeout)
        File.rm(without)
        [removed, restored]
      end)
    end
  end

  defp commit_ms(engine, out, inputs, timeout) do
    {micros, {:ok, _}} = :timer.tc(fn -> Engine.commit(engine, out, inputs, %{}, timeout) end)
    micros / 1000
  end

  # Every output's rows and a digest of them, in order, whatever order
  # the engine wrote them in.
  defp outputs(dir, manifest) do
    Map.new(manifest.outputs, fn %{name: name, file: file} ->
      rows =
        dir |> Path.join(file) |> File.read!() |> String.split("\n", trim: true) |> Enum.sort()

      digest = :crypto.hash(:sha256, Enum.intersperse(rows, "\n")) |> Base.encode16(case: :lower)
      {name, %{rows: length(rows), digest: binary_part(digest, 0, 16)}}
    end)
  end

  defp summarize(program, built, workers, [first | _] = runs) do
    usages = Enum.reject(Enum.map(runs, & &1.usage), &is_nil/1)

    %{
      program: name(program),
      engine: built.kind,
      workers: workers,
      outcome: first.outcome,
      cold_ms: Enum.map(runs, & &1.cold_ms),
      edit_ms: first.edits,
      bytes: if(first.usage, do: first.usage.bytes),
      peak_bytes: if(usages != [], do: Enum.max(Enum.map(usages, & &1.peak_bytes))),
      outputs: first.outputs
    }
  end

  # A program of argus's own by its path in the rules tree, whether named
  # where the build serves it or in the checkout's priv/dl: the same name
  # whichever way a run was asked for it.
  @source_dl Path.expand("../../../priv/dl", __DIR__)

  defp name(program) do
    Enum.find_value([Argus.Dl.root(), @source_dl], program, fn root ->
      if String.starts_with?(program, root <> "/"), do: Path.relative_to(program, root)
    end)
  end

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "argus_bench_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes `measures` to `path` as JSON."
  @spec write!(Path.t(), [measure()]) :: :ok
  def write!(path, measures) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"version" => 1, "measures" => measures}))
  end

  @doc "The measures `write!/2` wrote to `path`."
  @spec read!(Path.t()) :: [measure()]
  def read!(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"version" => 1, "measures" => measures} ->
        Enum.map(measures, &from_json/1)

      _ ->
        raise ArgumentError, "#{path} is not a benchmark's results (`mix argus.flowlog bench`)"
    end
  end

  defp from_json(json) do
    %{
      program: json["program"],
      engine: String.to_existing_atom(json["engine"]),
      workers: json["workers"],
      outcome: json["outcome"],
      cold_ms: json["cold_ms"],
      edit_ms: json["edit_ms"],
      bytes: json["bytes"],
      peak_bytes: json["peak_bytes"],
      outputs:
        Map.new(json["outputs"], fn {name, %{"rows" => rows, "digest" => digest}} ->
          {name, %{rows: rows, digest: digest}}
        end)
    }
  end

  @doc """
  How each program's `new` measure differs from its `old` one: its
  outputs (`:same`, or the relations whose rows differ, each with its
  rows before and after), and the change in time and memory as a ratio
  (`new / old`). A program measured on one side only is left out.
  """
  @spec compare([measure()], [measure()]) :: [
          %{
            program: String.t(),
            outputs: :same | [{String.t(), non_neg_integer() | nil, non_neg_integer() | nil}],
            cold: float() | nil,
            edit: float() | nil,
            peak: float() | nil,
            bytes: float() | nil
          }
        ]
  def compare(old, new) do
    old = Map.new(old, &{&1.program, &1})

    for measure <- new, before = Map.get(old, measure.program), before != nil do
      %{
        program: measure.program,
        outputs: outputs_changed(before, measure),
        cold: ratio(fastest(before.cold_ms), fastest(measure.cold_ms)),
        edit: ratio(median(before.edit_ms), median(measure.edit_ms)),
        peak: ratio(before.peak_bytes, measure.peak_bytes),
        bytes: ratio(before.bytes, measure.bytes)
      }
    end
  end

  defp outputs_changed(%{outcome: outcome} = before, %{outcome: outcome} = measure) do
    names = Enum.uniq(Map.keys(before.outputs) ++ Map.keys(measure.outputs))

    changed =
      for name <- Enum.sort(names),
          was = Map.get(before.outputs, name),
          now = Map.get(measure.outputs, name),
          was == nil or now == nil or was.digest != now.digest,
          do: {name, was && was.rows, now && now.rows}

    if changed == [], do: :same, else: changed
  end

  defp outputs_changed(before, measure),
    do: [{"(outcome: #{before.outcome} -> #{measure.outcome})", nil, nil}]

  @doc """
  Measures taken together: their fastest times from scratch and their
  edits' medians summed, as if solved one after another; the largest
  peak; and what their engines keep summed, as a session holding them
  all keeps it.
  """
  @spec total([measure()]) :: %{
          cold_ms: number(),
          edit_ms: number(),
          peak_bytes: non_neg_integer() | nil,
          bytes: non_neg_integer()
        }
  def total(measures) do
    peaks = for %{peak_bytes: peak} when is_integer(peak) <- measures, do: peak

    %{
      cold_ms: Enum.sum(Enum.map(measures, &(fastest(&1.cold_ms) || 0))),
      edit_ms: Enum.sum(Enum.map(measures, &(median(&1.edit_ms) || 0))),
      peak_bytes: if(peaks != [], do: Enum.max(peaks)),
      bytes: Enum.sum(Enum.map(measures, &(&1.bytes || 0)))
    }
  end

  @doc "The fastest of a run's times, or nil when there are none."
  @spec fastest([number()]) :: number() | nil
  def fastest([]), do: nil
  def fastest(times), do: Enum.min(times)

  @doc "The median of a list of times, or nil when there are none."
  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(times) do
    sorted = Enum.sort(times)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp ratio(nil, _), do: nil
  defp ratio(_, nil), do: nil
  defp ratio(old, _new) when old == 0, do: nil
  defp ratio(old, new), do: new / old
end
