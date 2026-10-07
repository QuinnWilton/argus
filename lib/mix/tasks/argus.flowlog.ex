defmodule Mix.Tasks.Argus.Flowlog do
  @shortdoc "Builds, inspects or cleans argus's FlowLog engines"

  @moduledoc """
  argus solves its analyses on FlowLog engines it compiles with Rust, once
  per version of their rules (`Argus.FlowLog.Toolchain`). This task does
  that work ahead of a run, and looks after the cache it lives in.

      mix argus.flowlog build            # the toolchain and every built-in engine
      mix argus.flowlog build PROGRAM... # the engines for these .dl programs
      mix argus.flowlog status           # Rust, the toolchain, and what is built
      mix argus.flowlog solve PROGRAM FACTS_DIR [OUT_DIR]
                                         # one solve of a program over a facts directory
      mix argus.flowlog clean            # remove the toolchains this argus no longer uses

  `solve` builds the program's engine if it must, loads every input from
  `FACTS_DIR` (`<relation>.facts`, tab-separated, unless the program names
  another file), and prints each output's rows, or writes every output
  file into `OUT_DIR`: what a contributor runs on an edited rule or an
  example (`examples/contributor`).

  `build` is what a first `mix compile` (with the `:argus` compiler) or
  `mix argus` would otherwise do as its analyses ask, a large program's
  engine taking minutes; run it in CI before the analyses, or once after
  upgrading argus. A program that does not compile, or that argus cannot
  host, fails with FlowLog's diagnostic.

  The cache is `$ARGUS_FLOWLOG_DIR`, else `$XDG_CACHE_HOME/argus/flowlog`,
  else `~/.cache/argus/flowlog`; `ARGUS_CARGO` names the `cargo` to build
  with.
  """

  use Mix.Task

  alias Argus.FlowLog
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

    case Toolchain.rust() do
      {:ok, rust} ->
        [release] = Regex.run(~r/^rustc .*$/m, rust.rustc_version)
        Mix.shell().info("rust:      #{release} (#{rust.cargo})")

      {:error, reason} ->
        Mix.shell().info("rust:      unavailable: " <> Toolchain.describe(reason))
    end

    Mix.shell().info("flowlog:   #{Argus.FlowLog.Native.flowlog_revision()}")
    Mix.shell().info("cache:     #{Toolchain.root()}")

    case Toolchain.stale(current_key()) do
      [] ->
        :ok

      stale ->
        Mix.shell().info(
          "stale:     #{length(stale)} toolchain(s) of other sources or another Rust " <>
            "(#{megabytes(stale)} MB); `mix argus.flowlog clean` removes them"
        )
    end

    case toolchain_status() do
      :not_built ->
        Mix.shell().info("toolchain: not built; `mix argus.flowlog build` builds it")

      {:ok, toolchain} ->
        Mix.shell().info("toolchain: #{toolchain.dir}")

        for path <- FlowLog.builtin_programs() do
          state =
            case FlowLog.manifest(path) do
              {:ok, manifest} ->
                digest = FlowLog.program_digest(path, Enum.map(manifest.inputs, & &1.name))

                if File.regular?(Argus.FlowLog.Program.executable(toolchain, digest)),
                  do: "built",
                  else: "not built"

              {:error, reason} ->
                "does not compile: " <> FlowLog.describe_error(reason)
            end

          Mix.shell().info("  #{Path.relative_to(path, Argus.Dl.root())}: #{state}")
        end

      {:error, reason} ->
        Mix.shell().info("toolchain: unavailable: " <> FlowLog.describe_error(reason))
    end
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
    stale = Toolchain.stale(current_key())
    freed = megabytes(stale)
    Enum.each(stale, &File.rm_rf!/1)

    Mix.shell().info(
      "argus: removed #{length(stale)} toolchain(s) (#{freed} MB) from #{Toolchain.root()}"
    )
  end

  def run(_args) do
    Mix.raise(
      "usage: mix argus.flowlog build [PROGRAM...] | status | solve PROGRAM FACTS_DIR [OUT_DIR] | clean"
    )
  end

  defp info(message), do: Mix.shell().info(message)

  # Status reports a toolchain; it never builds one (a build takes minutes).
  defp toolchain_status do
    with key when is_binary(key) <- current_key(),
         true <- File.regular?(Path.join([Toolchain.root(), key, "bin", "argus-flowlog-tool"])) do
      FlowLog.toolchain(progress: false)
    else
      _ -> :not_built
    end
  end

  # The toolchain this argus and this Rust use, which is kept; without a
  # Rust, none is usable.
  defp current_key do
    case Toolchain.rust() do
      {:ok, rust} -> Toolchain.key(rust)
      {:error, _} -> nil
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
