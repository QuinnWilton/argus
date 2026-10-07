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
      mix argus.flowlog solve PROGRAM FACTS_DIR [OUT_DIR]
                                         # one solve of a program over a facts directory
      mix argus.flowlog clean            # remove the toolchains and bundles this argus no longer uses
      mix argus.flowlog bundle OUT_DIR   # this platform's prebuilt engines, for a release
      mix argus.flowlog prebuilt BASE_URL OFFER.json...
                                         # write priv/flowlog/prebuilt.json from bundles' offers

  `solve` runs the program in the engine `ARGUS_FLOWLOG_ENGINE` chooses
  (the generic one, unless a compiled one is installed), loads every input from
  `FACTS_DIR` (`<relation>.facts`, tab-separated, unless the program names
  another file), and prints each output's rows, or writes every output
  file into `OUT_DIR`: what a contributor runs on an edited rule or an
  example (`examples/contributor`).

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

  def run(["solve", program, facts | out]) when length(out) <= 1 do
    Mix.Task.run("app.config")
    opts = [progress: &info/1] ++ Enum.map(out, &{:output_dir, Path.expand(&1)})
    Enum.each(out, &File.mkdir_p!/1)

    case FlowLog.run(Path.expand(facts), Path.expand(program), opts) do
      {:ok, results} ->
        for {relation, rows} <- Enum.sort(results) do
          info("#{relation}: #{length(rows)} row(s)")
          for row <- rows, do: info("  " <> Enum.join(row, "\t"))
        end

      {:error, %Argus.MissingRelationError{} = error} ->
        Mix.raise("argus: " <> Exception.message(error))

      {:error, reason} ->
        Mix.raise("argus: " <> FlowLog.describe_error(reason))
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

  def run(_args) do
    Mix.raise(
      "usage: mix argus.flowlog build [PROGRAM...] | status | solve PROGRAM FACTS_DIR [OUT_DIR] " <>
        "| clean | bundle OUT_DIR | prebuilt BASE_URL OFFER.json..."
    )
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
