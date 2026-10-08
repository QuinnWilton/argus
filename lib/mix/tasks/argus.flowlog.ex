defmodule Mix.Tasks.Argus.Flowlog do
  @shortdoc "Builds, inspects or cleans argus's FlowLog engines"

  @moduledoc """
  argus solves its analyses on FlowLog engines (`Argus.FlowLog.engine/2`):
  the generic engine, the toolchain's tool, which runs any program it
  supports at once, or an engine compiled for the program, built with
  Rust once per version of its rules (`Argus.FlowLog.Toolchain`) and up to
  twice as fast on a large project. This task builds compiled engines
  ahead of a run, and looks after the cache they live in.

      mix argus.flowlog build            # the toolchain and every built-in engine
      mix argus.flowlog build PROGRAM... # the engines for these .dl programs
      mix argus.flowlog status           # Rust, the toolchain, and what is built
      mix argus.flowlog solve PROGRAM FACTS_DIR [OUT_DIR] [--profile]
                                         # one solve of a program over a facts directory
      mix argus.flowlog facts OUT_DIR (--checkout NAME | --ebin DIR... | --beam FILE...)
                                         # every fact and stage output argus's programs read
      mix argus.flowlog bench FACTS_DIR [PROGRAM...] [--runs N] [--edits N]
                              [--save FILE] [--against FILE] [--engine generic|compiled]
                                         # time, memory and outputs of solves over FACTS_DIR
      mix argus.flowlog clean            # remove the toolchains and bundles this argus no longer uses
      mix argus.flowlog bundle OUT_DIR   # this platform's prebuilt engines, for a release
      mix argus.flowlog prebuilt BASE_URL OFFER.json...
                                         # write priv/flowlog/prebuilt.json from bundles' offers

  `solve` runs the program in the engine `ARGUS_FLOWLOG_ENGINE` chooses
  (the generic one, unless a compiled one is installed), loads every input from
  `FACTS_DIR` (`<relation>.facts`, tab-separated, unless the program names
  another file), and prints each output's rows, or writes every output
  file into `OUT_DIR`: what a contributor runs on an edited rule or an
  example (`examples/contributor`). With `--profile` it runs in the generic
  engine and prints where the solve's memory and time went: the
  arrangements holding the most updates and the operators that ran the
  longest, each named by the relation or rule expression it is of (`σ` a
  map of one, `⋈` a join, `▷` the rows an antijoin keeps); a rule whose
  join holds millions of updates is the one to restate.

  `facts` extracts a project's facts into `OUT_DIR` once, with every
  stage's outputs (`Argus.Analysis.extract_facts/3` for every analysis):
  a corpus checkout's (`--checkout ash-09f4259`, as `mix argus.corpus
  fetch` names them), or the beams of ebin directories or files.

  `bench` solves each program (default every built-in program whose
  inputs `FACTS_DIR` holds) in fresh engines and prints how long the
  solve took from scratch (the fastest of `--runs`, default 1), the
  median of `--edits` one-row edits' commits (default 3: a row of the
  largest input taken out and put back), the engine's peak memory and
  what it kept, and its outputs (`Argus.FlowLog.Bench`). `--save` keeps
  the measures as JSON, and `--against` compares with saved ones: each
  change in time and memory, and whether every output is the same rows,
  naming the relations that are not. Save before a change to an engine
  or a rule meant only to make it faster, and compare after: the rows
  must not move.

  `build` compiles engines, a large program's taking minutes; the
  analyses then run in them instead of the generic engine. Run it in CI
  before the analyses, or once after upgrading argus. A program that does
  not compile, or that argus cannot host, fails with FlowLog's diagnostic.

  `bundle` and `prebuilt` are a release's (`.github/workflows/release.yml`):
  each platform's build writes its bundle of the tool and every built-in
  engine with its offer (`Argus.FlowLog.Prebuilt`), and `prebuilt` names
  them all, by URL and SHA-256, in the package argus publishes. A
  machine of a platform with a bundle then needs no Rust for argus's own
  analyses.

  The cache is `$ARGUS_FLOWLOG_DIR`, else `$XDG_CACHE_HOME/argus/flowlog`,
  else `~/.cache/argus/flowlog`; `ARGUS_CARGO` names the `cargo` to build
  with.
  """

  use Mix.Task

  alias Argus.FlowLog
  alias Argus.FlowLog.Bench
  alias Argus.FlowLog.Native
  alias Argus.FlowLog.Prebuilt
  alias Argus.FlowLog.Program
  alias Argus.FlowLog.Toolchain

  @impl Mix.Task
  def run(["build" | programs]) do
    Mix.Task.run("app.config")

    programs =
      if programs == [], do: FlowLog.builtin_programs(), else: Enum.map(programs, &Path.expand/1)

    case FlowLog.prebuild(programs, progress: &info/1) do
      :ok -> Mix.shell().info("argus: #{length(programs)} FlowLog engine(s) built")
      {:error, reason} -> Mix.raise("argus: " <> FlowLog.describe_error(reason))
    end
  end

  def run(["status"]) do
    Mix.Task.run("app.config")
    status()
  end

  def run(["solve" | args]) do
    case OptionParser.parse(args, strict: [profile: :boolean]) do
      {switches, [program, facts | out], []} when length(out) <= 1 ->
        solve(program, facts, out, Keyword.get(switches, :profile, false))

      _ ->
        Mix.raise(usage())
    end
  end

  def run(["facts" | args]) do
    case OptionParser.parse(args, strict: [checkout: :string, ebin: :keep, beam: :keep]) do
      {opts, [out], []} when opts != [] -> facts(Path.expand(out), opts)
      _ -> Mix.raise(usage())
    end
  end

  def run(["bench" | args]) do
    switches = [
      runs: :integer,
      edits: :integer,
      save: :string,
      against: :string,
      engine: :string
    ]

    case OptionParser.parse(args, strict: switches) do
      {opts, [facts | programs], []} -> bench(Path.expand(facts), programs, opts)
      _ -> Mix.raise(usage())
    end
  end

  def run(["clean"]) do
    Mix.Task.run("app.config")
    stale = Toolchain.stale(Toolchain.current_key()) ++ Prebuilt.stale()
    freed = megabytes(stale)
    Enum.each(stale, &File.rm_rf!/1)

    Mix.shell().info(
      "argus: removed #{length(stale)} unused toolchain(s) and bundle(s) (#{freed} MB) " <>
        "from #{Toolchain.root()}"
    )
  end

  def run(["bundle", out_dir]) do
    Mix.Task.run("app.config")
    # A bundle is what this machine builds, never what another release
    # bundled.
    System.put_env("ARGUS_FLOWLOG_PREBUILT", "0")
    programs = FlowLog.builtin_programs()

    with :ok <- FlowLog.prebuild(programs, progress: &info/1),
         {:ok, toolchain} <- FlowLog.toolchain(progress: false),
         {:ok, engines} <- bundled_engines(toolchain, programs),
         {:ok, offer} <-
           Prebuilt.write_bundle(
             Toolchain.tool(toolchain),
             engines,
             Path.expand(out_dir)
           ) do
      info(
        "argus: wrote #{Path.rootname(offer)} (#{length(engines)} engines) and its offer #{offer}"
      )
    else
      {:error, reason} -> Mix.raise("argus: " <> describe(reason))
    end
  end

  def run(["prebuilt", base_url | offers]) when offers != [] do
    Mix.Task.run("app.config")
    target = Path.join(["priv", "flowlog", "prebuilt.json"])

    case Prebuilt.offer_json(offers, base_url) do
      {:ok, json} ->
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, json)
        info("argus: wrote #{target} naming #{length(offers)} bundle(s)")

      {:error, message} ->
        Mix.raise("argus: " <> message)
    end
  end

  def run(_args), do: Mix.raise(usage())

  defp usage do
    "usage: mix argus.flowlog build [PROGRAM...] | status " <>
      "| solve PROGRAM FACTS_DIR [OUT_DIR] [--profile] " <>
      "| facts OUT_DIR (--checkout NAME | --ebin DIR... | --beam FILE...) " <>
      "| bench FACTS_DIR [PROGRAM...] [--runs N] [--edits N] [--save FILE] [--against FILE] " <>
      "[--engine generic|compiled] " <>
      "| clean | bundle OUT_DIR | prebuilt BASE_URL OFFER.json..."
  end

  defp solve(program, facts, out, profile?) do
    Mix.Task.run("app.config")
    Enum.each(out, &File.mkdir_p!/1)

    report =
      if profile?,
        do:
          Path.join(System.tmp_dir!(), "argus-profile-#{System.unique_integer([:positive])}.json")

    opts =
      [progress: &info/1] ++
        Enum.map(out, &{:output_dir, Path.expand(&1)}) ++
        if(report, do: [profile: report], else: [])

    try do
      case FlowLog.run(Path.expand(facts), Path.expand(program), opts) do
        {:ok, results} ->
          for {relation, rows} <- Enum.sort(results) do
            info("#{relation}: #{length(rows)} row(s)")
            for row <- rows, do: info("  " <> Enum.join(row, "\t"))
          end

          if report, do: print_profile(report)

        {:error, %Argus.MissingRelationError{} = error} ->
          Mix.raise("argus: " <> Exception.message(error))

        {:error, reason} ->
          # A solve stopped part way (a `.limitsize`) still measured.
          if report && File.regular?(report), do: print_profile(report)
          Mix.raise("argus: " <> FlowLog.describe_error(reason))
      end
    after
      if report, do: File.rm(report)
    end
  end

  defp facts(out, opts) do
    Mix.Task.run("app.config")
    beams = facts_beams(opts)
    info("argus: extracting the facts of #{length(beams)} beams")

    case Argus.Analysis.extract_facts(beams, Argus.Analysis.Catalog.names(), timeout: :infinity) do
      {:ok, dir} ->
        try do
          File.rm_rf!(out)
          File.mkdir_p!(Path.dirname(out))
          File.cp_r!(dir, out)
          info("argus: wrote #{length(File.ls!(out))} relations' facts into #{out}")
        after
          File.rm_rf(Path.dirname(dir))
        end

      {:error, reason} ->
        Mix.raise("argus: extracting facts failed: #{inspect(reason)}")
    end
  end

  defp facts_beams(opts) do
    from_checkout =
      case Keyword.get(opts, :checkout) do
        nil -> []
        name -> checkout_beams(name)
      end

    from_ebins =
      for dir <- Keyword.get_values(opts, :ebin),
          beam <- Path.wildcard(Path.join(Path.expand(dir), "*.beam")),
          do: beam

    beams =
      from_checkout ++ from_ebins ++ Enum.map(Keyword.get_values(opts, :beam), &Path.expand/1)

    if beams == [], do: Mix.raise("argus: no beams to extract facts from"), else: beams
  end

  defp checkout_beams(name) do
    checkouts = Argus.Corpus.checkouts(Argus.Corpus.pairs())

    case Enum.find(checkouts, fn {co, _pair, _side} -> co.name == name end) do
      nil ->
        Mix.raise(
          "argus: no corpus checkout is named #{name}; they are named <repo>-<sha7>, " <>
            "as `mix argus.corpus fetch` prints them"
        )

      {_co, pair, side} ->
        case Argus.Corpus.ensure(pair, side) do
          {:ok, beams} -> beams
          {:skip, why} -> Mix.raise("argus: #{name} cannot be built here: #{why}")
          {:error, why} -> Mix.raise("argus: #{name}: #{why}")
        end
    end
  end

  defp bench(facts, programs, opts) do
    Mix.Task.run("app.config")

    unless File.dir?(facts), do: Mix.raise("argus: #{facts} is not a directory of facts")

    {ready, lacking} =
      if programs == [],
        do: Bench.programs(facts),
        else: Bench.programs(facts, Enum.map(programs, &Path.expand/1))

    for {path, missing} <- lacking do
      info("#{Path.basename(path)}: not measured, #{facts} has no #{Enum.join(missing, ", ")}")
    end

    against = if path = opts[:against], do: Bench.read!(Path.expand(path))

    measure_opts =
      [runs: Keyword.get(opts, :runs, 1), edits: Keyword.get(opts, :edits, 3)] ++
        engine_option(opts[:engine])

    measures =
      for program <- ready do
        case Bench.measure(facts, program, measure_opts) do
          {:ok, measure} ->
            print_measure(measure, against)
            measure

          {:error, reason} ->
            Mix.raise("argus: #{Path.basename(program)}: " <> FlowLog.describe_error(reason))
        end
      end

    if path = opts[:save] do
      Bench.write!(Path.expand(path), measures)
      info("argus: saved #{length(measures)} measure(s) to #{path}")
    end

    if against, do: print_verdict(Bench.compare(against, measures))
  end

  defp engine_option(nil), do: []
  defp engine_option("generic"), do: [engine: :generic]
  defp engine_option("compiled"), do: [engine: :compiled]
  defp engine_option(other), do: Mix.raise("argus: --engine is generic or compiled, not #{other}")

  defp print_measure(measure, against) do
    before = against && Enum.find(against, &(&1.program == measure.program))

    cells = [
      "cold " <>
        change(
          &seconds/1,
          Bench.fastest(measure.cold_ms),
          before && Bench.fastest(before.cold_ms)
        ),
      "edit " <>
        change(&millis/1, Bench.median(measure.edit_ms), before && Bench.median(before.edit_ms)),
      "peak " <> change(&mb/1, measure.peak_bytes, before && before.peak_bytes),
      "kept " <> change(&mb/1, measure.bytes, before && before.bytes)
    ]

    outcome = if measure.outcome == "ok", do: "", else: "  " <> measure.outcome

    info(
      "#{String.pad_trailing(measure.program, 30)} #{measure.engine}  " <>
        Enum.join(cells, "  ") <> "  #{map_size(measure.outputs)} outputs" <> outcome
    )
  end

  defp change(format, nil, _before), do: format.(nil)
  defp change(format, now, nil), do: format.(now)
  defp change(format, now, before) when before == 0, do: format.(now)

  defp change(format, now, before) do
    percent = round((now / before - 1) * 100)
    sign = if percent > 0, do: "+", else: ""
    "#{format.(now)} (#{sign}#{percent}%)"
  end

  defp seconds(nil), do: "-"
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"
  defp millis(nil), do: "-"
  defp millis(ms), do: "#{round(ms)}ms"
  defp mb(nil), do: "-"
  defp mb(bytes), do: "#{div(bytes, 1_000_000)} MB"

  defp print_verdict(comparisons) do
    differing = Enum.reject(comparisons, &(&1.outputs == :same))

    if differing == [] do
      info(
        "argus: every output is the same rows as the saved run's (#{length(comparisons)} programs)"
      )
    else
      info("argus: outputs differ from the saved run's:")

      for %{program: program, outputs: outputs} <- differing,
          {relation, was, now} <- outputs do
        info("  #{program}: #{relation}: #{rows(was)} -> #{rows(now)} rows")
      end
    end
  end

  defp rows(nil), do: "none"
  defp rows(n), do: grouped(n)

  @arrangements 20
  @operators 12

  defp print_profile(report) do
    profile = report |> File.read!() |> :json.decode()
    info("")
    info("profile: #{grouped(profile["arranged"])} updates held in arrangements")
    info("  #{String.pad_leading("updates", 12)}  arrangement")

    for %{"name" => name, "updates" => updates} <-
          Enum.take(profile["arrangements"], @arrangements) do
      info("  #{String.pad_leading(grouped(updates), 12)}  #{name}")
    end

    info("  #{String.pad_leading("seconds", 12)}  operator")

    for %{"name" => name, "seconds" => seconds} <- Enum.take(profile["operators"], @operators) do
      info("  #{String.pad_leading(:erlang.float_to_binary(seconds, decimals: 3), 12)}  #{name}")
    end
  end

  defp grouped(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp status do
    info("rust:      " <> rust_status())
    info("flowlog:   #{Native.flowlog_revision()}")
    info("cache:     #{Toolchain.root()}")
    info("prebuilt:  " <> prebuilt_status())

    case Toolchain.stale(Toolchain.current_key()) do
      [] ->
        :ok

      stale ->
        info(
          "stale:     #{length(stale)} toolchain(s) of other sources or another Rust " <>
            "(#{megabytes(stale)} MB); `mix argus.flowlog clean` removes them"
        )
    end

    case toolchain_status() do
      :not_built ->
        info("toolchain: not built; `mix argus.flowlog build` builds it")

      {:ok, toolchain} ->
        info("toolchain: #{toolchain.dir}")

        for path <- FlowLog.builtin_programs(),
            do:
              info(
                "  #{Path.relative_to(path, Argus.Dl.root())}: #{engine_status(toolchain, path)}"
              )

      {:error, reason} ->
        info("toolchain: unavailable: " <> FlowLog.describe_error(reason))
    end
  end

  defp rust_status do
    case {Toolchain.rust(), Prebuilt.offer()} do
      {{:ok, rust}, _} ->
        [release] = Regex.run(~r/^rustc .*$/m, rust.rustc_version)
        "#{release} (#{rust.cargo})"

      {{:error, reason}, {:ok, _}} ->
        "unavailable: argus's own analyses run on its prebuilt engines, and a program " <>
          "of your own in the generic engine; one that engine does not run needs Rust " <>
          "(#{Toolchain.describe(reason)})"

      {{:error, reason}, {:error, _}} ->
        "unavailable: " <> Toolchain.describe(reason)
    end
  end

  defp prebuilt_status do
    case Prebuilt.offer() do
      {:ok, offer} -> "#{offer.url} (#{div(offer.bytes, 1_000_000)} MB)"
      {:error, reason} -> "none: " <> Prebuilt.describe(reason)
    end
  end

  defp engine_status(toolchain, path) do
    case FlowLog.manifest(path) do
      {:ok, manifest} ->
        digest = FlowLog.program_digest(path, Enum.map(manifest.inputs, & &1.name))

        cond do
          Program.installed(toolchain, digest, Program.profile(path)) -> "built"
          manifest.generic -> "not built: runs in the generic engine"
          true -> "not built"
        end

      {:error, reason} ->
        "does not compile: " <> FlowLog.describe_error(reason)
    end
  end

  defp info(message), do: Mix.shell().info(message)

  defp describe(reason)
       when is_tuple(reason) and elem(reason, 0) in [:download_failed, :bad_bundle],
       do: Prebuilt.describe(reason)

  defp describe(reason), do: FlowLog.describe_error(reason)

  defp bundled_engines(toolchain, programs) do
    Enum.reduce_while(programs, {:ok, []}, fn path, {:ok, acc} ->
      case FlowLog.engine(path, progress: false) do
        {:ok, built} ->
          engine = Program.executable(toolchain, built.digest)
          manifest = Path.join(Path.dirname(engine), "manifest.json")
          program = Path.relative_to(path, Argus.Dl.root())
          {:cont, {:ok, acc ++ [{program, built.digest, engine, manifest}]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Status reports a toolchain; it never builds or downloads one.
  defp toolchain_status do
    with key when is_binary(key) <- Toolchain.current_key(),
         true <- File.regular?(Path.join([Toolchain.root(), key, "bin", "argus-flowlog-tool"])) do
      FlowLog.toolchain(progress: false)
    else
      _ -> :not_built
    end
  end

  defp megabytes(dirs), do: div(Enum.sum(Enum.map(dirs, &bytes/1)), 1_000_000)

  defp bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path |> File.ls!() |> Enum.map(&bytes(Path.join(path, &1))) |> Enum.sum()

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _} ->
        0
    end
  end
end
