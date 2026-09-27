defmodule Argus.CLI do
  @moduledoc """
  The `argus` escript: argus's analyses over a built project that is
  not a Mix project — rebar3, Gleam, erlang.mk, or bare ebins — with the
  same findings, rendered the same way, as the `:argus` Mix compiler and
  `mix argus` (see `Argus.CLI.Options` for the command line).

  The escript never builds a project: it reads the beams the build
  left (`Argus.Project`), and names the build command when there are
  none, or when sources are newer than their beams. A Mix project is
  `mix argus`'s, which runs in the project's own VM and compiles it.

  Exit status: 0 done; 1 more findings than `--fail-above`; 2 a usage,
  project or configuration error; 3 the analyses could not run or did
  not finish (no souffle, an analysis that degraded, a crash).
  """

  alias Argus.CLI.Options
  alias Argus.Report
  alias Argus.Report.Notice

  @typedoc "An exit status (see the moduledoc)."
  @type status :: 0..3

  @doc "The escript's entry point: runs `argv` and halts with its status."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    status = run(argv)
    System.halt(status)
  end

  @doc """
  Runs the command line `argv`, printing what it prints, and returns the
  exit status without halting.
  """
  @spec run([String.t()]) :: status()
  def run(argv) do
    case Options.parse(argv, :escript) do
      {:ok, options} -> command(options)
      {:error, message} -> usage_error(message)
    end
  end

  defp command(%Options{command: :help}) do
    IO.write(Options.usage())
    0
  end

  defp command(%Options{command: :version}) do
    IO.puts(version())
    0
  end

  defp command(%Options{command: :list}) do
    IO.write(list())
    0
  end

  defp command(%Options{command: :gc} = options), do: gc(options)
  defp command(%Options{command: :analyze} = options), do: analyze(options)

  defp usage_error(message) do
    IO.puts(:stderr, "argus: " <> message)
    IO.puts(:stderr, "Run `argus help` for the usage.")
    2
  end

  defp error(status, message) do
    IO.puts(:stderr, "argus: " <> message)
    status
  end

  # ── analyze ──────────────────────────────────────────────────────────

  defp analyze(%Options{} = options) do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    cwd = File.cwd!()

    with {:ok, root} <- root(options),
         {:ok, kind} <- kind(root, options),
         {:ok, project} <- load(kind, root, options),
         {:ok, config} <- config(root, kind, options) do
      if Argus.Souffle.available?() do
        drive(project, config, options, cwd)
      else
        error(3, Notice.souffle_missing(:require).message)
      end
    else
      {:error, status, message} -> error(status, message)
    end
  end

  defp root(%Options{root: root, dir: dir}) do
    case {root, dir} do
      {nil, nil} ->
        {:ok, File.cwd!()}

      {nil, dir} ->
        existing(dir)

      {root, nil} ->
        existing(root)

      {root, dir} ->
        if Path.expand(root) == Path.expand(dir),
          do: existing(root),
          else: {:error, 2, "--root #{root} and DIR #{dir} name two projects"}
    end
  end

  defp existing(dir) do
    if File.dir?(dir),
      do: {:ok, Path.expand(dir)},
      else: {:error, 2, "#{dir} is not a directory"}
  end

  defp kind(root, %Options{project: nil, ebins: []}) do
    case Argus.Project.detect(root) do
      {:ok, :mix} ->
        {:error, 2, mix_project(root)}

      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error, 2,
         "no rebar3, Gleam or erlang.mk project in #{root}: name one with --project, " <>
           "or its ebins with --ebin"}
    end
  end

  defp kind(_root, %Options{project: nil}), do: {:ok, :beams}
  defp kind(root, %Options{project: :mix}), do: {:error, 2, mix_project(root)}
  defp kind(_root, %Options{project: kind}), do: {:ok, kind}

  defp mix_project(root) do
    "#{root} is a Mix project: run `mix argus` in it " <>
      "(with {:panoptes, ...} among its dependencies), which compiles it first"
  end

  defp load(kind, root, options) do
    opts =
      [
        profile: options.profile,
        apps: nonempty(options.apps),
        deps: nonempty(options.deps),
        ebins: options.ebins,
        dep_ebins: options.dep_ebins,
        state_dir: options.state_dir && Path.expand(options.state_dir)
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

    case Argus.Project.load(kind, root, opts) do
      {:ok, project} -> {:ok, project}
      {:error, message} -> {:error, 2, message}
    end
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp config(root, kind, options) do
    {raw, origin} = Argus.Config.Source.for_project(root, kind, options.config)
    {:ok, override(Argus.Config.load(raw, origin), options)}
  rescue
    error in Argus.ConfigError -> {:error, 2, String.replace_prefix(error.message, "argus: ", "")}
  end

  @doc """
  `config` with the command line's overrides: its analyses (validated
  as the configuration's are) or every analysis, and `--include-deps`.
  """
  @spec override(Argus.Config.t(), Options.t()) :: Argus.Config.t()
  def override(%Argus.Config{} = config, %Options{} = options) do
    analyses =
      cond do
        options.all -> Argus.Config.all_analyses()
        options.analyses -> Argus.Config.analyses(options.analyses, :cli)
        true -> config.analyses
      end

    include_deps =
      if is_nil(options.include_deps), do: config.include_deps, else: options.include_deps

    %{config | analyses: analyses, include_deps: include_deps}
  end

  defp drive(project, config, options, cwd) do
    stale = Argus.Project.stale(project)
    identity = identity()
    moved? = identity_moved?(project, identity)

    result = Argus.Driver.run(config, project: project, force: options.force or moved?)

    if moved?, do: keep_identity(project, identity)

    notices =
      stale_notice(stale, project) ++ Notice.from_result(result, config, cwd)

    %{status: status} = report(result, notices, config, options, project.root, cwd)
    status
  rescue
    exception ->
      error(3, "the run failed: " <> Exception.format_banner(:error, exception, __STACKTRACE__))
  end

  # The escript's code, named by the digest of the escript itself: what
  # its manifest was computed by. A manifest another build of argus wrote
  # is not read at all (the run is cold), whatever the graph's own code
  # versions say — code inside an archive has no stamp of its own to
  # check them by. Outside an escript (`mix argus`, a test) there is
  # none, and the graph's versions alone decide.
  defp identity do
    case escript() do
      nil ->
        nil

      path ->
        case File.read(path) do
          {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          {:error, _} -> nil
        end
    end
  end

  # :escript.script_name/0 raises outside an escript.
  defp escript do
    path = List.to_string(:escript.script_name())
    if File.regular?(path), do: path
  rescue
    _ -> nil
  end

  defp identity_moved?(_project, nil), do: false

  defp identity_moved?(project, identity) do
    File.read(identity_file(project)) != {:ok, identity}
  end

  defp keep_identity(project, identity) do
    File.mkdir_p!(project.state_dir)
    File.write!(identity_file(project), identity)
  end

  defp identity_file(project), do: Path.join(project.state_dir, "escript")

  defp stale_notice([], _project), do: []
  defp stale_notice(stale, project), do: [Notice.stale(stale, project.build)]

  @doc """
  Renders a driver run — the notices, then the findings — as `options`
  ask (`--format`, `--color`), and says how it went: the entries, and
  the exit status (1 when there are more findings than `--fail-above`,
  3 when an analysis degraded, else 0). Ignored files are matched
  relative to `root`; paths are shown relative to `cwd`. Shared by the
  escript and `mix argus`.
  """
  @spec report(
          Argus.Driver.Result.t(),
          [Notice.t()],
          Argus.Config.t(),
          Options.t(),
          Path.t(),
          Path.t()
        ) :: %{entries: [Report.Entry.t()], status: status()}
  def report(result, notices, config, options, root, cwd) do
    entries = Report.build(result.located, config, root)

    case options.format do
      :text ->
        Report.Text.print(entries, notices, cwd, color: options.color)

      :json ->
        Enum.each(notices, &IO.puts(:stderr, Report.Text.notice(&1)))
        Report.Json.print(entries, cwd)
    end

    status =
      cond do
        Argus.Driver.Result.degraded(result) != [] -> 3
        over?(entries, options.fail_above) -> 1
        true -> 0
      end

    %{entries: entries, status: status}
  end

  defp over?(_entries, nil), do: false
  defp over?(entries, threshold), do: length(entries) > threshold

  # ── list, gc, version ────────────────────────────────────────────────

  @doc "The analyses (the default set marked) and the named sets, as `argus list` prints them."
  @spec list() :: String.t()
  def list do
    default = Argus.Graph.default_analyses()

    rows =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.reject(&(&1.name() == :coverage))
      |> Enum.sort_by(& &1.name())
      |> Enum.map_join("\n", fn mod ->
        marker = if mod.name() in default, do: "*", else: " "
        "  #{marker} #{mod.name()} — #{mod.description()}"
      end)

    sets =
      Argus.Analysis.sets()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, members} -> "    #{name}: #{Enum.join(members, " ")}" end)

    "Available analyses (* = in the default set):\n\n#{rows}\n\n" <>
      "Sets (as an analysis name in config or on the command line):\n\n#{sets}\n"
  end

  defp gc(options) do
    dir = Argus.Dirs.store()

    if File.dir?(dir) do
      case Roux.Blob.open(dir) do
        {:ok, store} ->
          gc_opts = Enum.reject([grace: options.grace, keep: options.keep], &is_nil(elem(&1, 1)))
          stats = Roux.Blob.gc(store, gc_opts)
          rules = gc_rules(Argus.Dirs.dl())

          IO.puts(
            "argus gc: #{dir}: removed #{stats.removed} " <>
              "(#{stats.bytes} bytes), kept #{stats.kept}" <>
              if(rules > 0,
                do: "; removed #{rules} unpacked rule trees of other versions",
                else: ""
              )
          )

          0

        {:error, %Roux.Blob.TrustError{} = trust} ->
          error(3, Exception.message(trust))

        {:error, reason} ->
          error(3, "#{dir} is not a store argus can collect: #{inspect(reason)}")
      end
    else
      IO.puts("argus gc: #{dir}: nothing to collect")
      0
    end
  end

  # The rules other escripts unpacked (`Argus.Dl`), untouched for a day:
  # another version's tree is never read again by this one.
  defp gc_rules(dir) do
    current = Argus.Dl.Embedded.digest()
    day_ago = System.os_time(:second) - 24 * 60 * 60

    for name <- ls(dir),
        name != current,
        path = Path.join(dir, name),
        match?(
          {:ok, %File.Stat{mtime: mtime}} when mtime < day_ago,
          File.stat(path, time: :posix)
        ),
        reduce: 0 do
      removed ->
        File.rm_rf(path)
        removed + 1
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  @doc "argus's version, the runtime's, and the solver's."
  @spec version() :: String.t()
  def version do
    _ = Application.load(:panoptes)
    vsn = Application.spec(:panoptes, :vsn) || ~c"unknown"

    souffle =
      case Argus.Souffle.executable() do
        nil -> "souffle not found on PATH"
        bin -> "souffle #{souffle_version(bin)}"
      end

    "argus #{vsn} (Erlang/OTP #{System.otp_release()}, Elixir #{System.version()}, #{souffle})"
  end

  defp souffle_version(bin) do
    case System.cmd(bin, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/^Version:\s*(\S+)/m, out) do
          [_, version] -> version
          nil -> "(unrecognized version)"
        end

      _ ->
        "(unrecognized version)"
    end
  rescue
    ErlangError -> "(cannot run)"
  end
end
