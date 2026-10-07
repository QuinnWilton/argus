defmodule Argus.CLI.Options do
  @moduledoc """
  The command line of the `argus` escript and of `mix argus`, parsed
  once for both (`parse/2`).

  The escript:

      argus [analyze] [DIR] [options]   analyze the built project in DIR (default .)
      argus list                        the analyses and the named sets
      argus gc [--grace S] [--keep S]   collect the blob store
      argus version                     argus's, the runtime's and the engine toolchain's versions
      argus help                        this text

  `mix argus` takes the analyses as positional arguments
  (`mix argus coupling ets`) and `--list`, and runs in the project Mix
  is in, so the project options (`--project`, `--profile`, `--app`,
  `--dep`, `--ebin`, `--dep-ebin`, `--root`, `--state-dir`, `--config`)
  are the escript's alone.

  A usage error is `{:error, message}`: the escript exits 2 with it,
  `mix argus` raises it.
  """

  @enforce_keys []
  defstruct command: :analyze,
            dir: nil,
            root: nil,
            project: nil,
            profile: nil,
            apps: [],
            deps: [],
            ebins: [],
            dep_ebins: [],
            analyses: nil,
            all: false,
            format: :text,
            fail_above: nil,
            include_deps: nil,
            force: false,
            state_dir: nil,
            config: nil,
            color: :auto,
            grace: nil,
            keep: nil

  @typedoc "What the command line asks for."
  @type t :: %__MODULE__{
          command: :analyze | :list | :gc | :version | :help,
          dir: Path.t() | nil,
          root: Path.t() | nil,
          project: Argus.Project.kind() | nil,
          profile: String.t() | nil,
          apps: [Argus.Project.ebin()],
          deps: [Argus.Project.ebin()],
          ebins: [Path.t()],
          dep_ebins: [Path.t()],
          analyses: [atom()] | nil,
          all: boolean(),
          format: :text | :json,
          fail_above: non_neg_integer() | nil,
          include_deps: boolean() | nil,
          force: boolean(),
          state_dir: Path.t() | nil,
          config: Path.t() | nil,
          color: :auto | :always | :never,
          grace: non_neg_integer() | nil,
          keep: non_neg_integer() | nil
        }

  @shared [
    analyses: :string,
    all: :boolean,
    format: :string,
    fail_above: :integer,
    include_deps: :boolean,
    force: :boolean,
    color: :string,
    help: :boolean
  ]

  @escript @shared ++
             [
               project: :string,
               profile: :string,
               app: :keep,
               dep: :keep,
               ebin: :keep,
               dep_ebin: :keep,
               root: :string,
               state_dir: :string,
               config: :string,
               grace: :integer,
               keep: :integer,
               version: :boolean
             ]

  @mix @shared ++ [list: :boolean]

  @commands %{
    "analyze" => :analyze,
    "list" => :list,
    "gc" => :gc,
    "version" => :version,
    "help" => :help
  }

  @doc """
  Parses `argv` as the escript (`:escript`) or `mix argus` (`:mix`)
  reads it.
  """
  @spec parse([String.t()], :escript | :mix) :: {:ok, t()} | {:error, String.t()}
  def parse(argv, mode) when mode in [:escript, :mix] do
    switches = if mode == :escript, do: @escript, else: @mix

    case OptionParser.parse(argv, strict: switches, aliases: [h: :help]) do
      {opts, positional, []} ->
        with {:ok, options} <- positional(mode, positional, opts) do
          build(options, opts)
        end

      {_opts, _positional, invalid} ->
        {:error, "unknown or malformed options: " <> Enum.map_join(invalid, ", ", &flag/1)}
    end
  end

  defp flag({name, nil}), do: name
  defp flag({name, value}), do: "#{name} #{value}"

  # The escript: [command] [DIR]. `mix argus`: the analyses.
  defp positional(:escript, positional, opts) do
    {command, rest} =
      case positional do
        [word | rest] when is_map_key(@commands, word) -> {Map.fetch!(@commands, word), rest}
        rest -> {:analyze, rest}
      end

    command =
      cond do
        opts[:help] -> :help
        opts[:version] -> :version
        true -> command
      end

    case {command, rest} do
      {:analyze, []} -> {:ok, %__MODULE__{command: :analyze}}
      {:analyze, [dir]} -> {:ok, %__MODULE__{command: :analyze, dir: dir}}
      {command, []} -> {:ok, %__MODULE__{command: command}}
      {_command, extra} -> {:error, "unexpected arguments: #{Enum.join(extra, " ")}"}
    end
  end

  defp positional(:mix, positional, opts) do
    command =
      cond do
        opts[:help] -> :help
        opts[:list] -> :list
        true -> :analyze
      end

    case positional do
      [] -> {:ok, %__MODULE__{command: command}}
      names -> {:ok, %__MODULE__{command: command, analyses: Enum.map(names, &analysis/1)}}
    end
  end

  defp build(options, opts) do
    with {:ok, format} <- one_of(opts, :format, ~w(text json)a, :text),
         {:ok, color} <- one_of(opts, :color, ~w(auto always never)a, :auto),
         {:ok, project} <- project(opts[:project]),
         {:ok, apps} <- pairs(Keyword.get_values(opts, :app), "--app"),
         {:ok, deps} <- pairs(Keyword.get_values(opts, :dep), "--dep"),
         {:ok, analyses} <- analyses(options.analyses, opts[:analyses], opts[:all]),
         :ok <- non_negative(opts, [:fail_above, :grace, :keep]),
         :ok <- profile(opts[:profile], project) do
      {:ok,
       %{
         options
         | root: opts[:root],
           project: project,
           profile: opts[:profile],
           apps: apps,
           deps: deps,
           ebins: Keyword.get_values(opts, :ebin),
           dep_ebins: Keyword.get_values(opts, :dep_ebin),
           analyses: analyses,
           all: Keyword.get(opts, :all, false),
           format: format,
           fail_above: opts[:fail_above],
           include_deps: opts[:include_deps],
           force: Keyword.get(opts, :force, false),
           state_dir: opts[:state_dir],
           config: opts[:config],
           color: color,
           grace: opts[:grace],
           keep: opts[:keep]
       }}
    end
  end

  defp one_of(opts, key, allowed, default) do
    value = Keyword.get(opts, key, Atom.to_string(default))

    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil ->
        {:error, "--#{dashed(key)} must be one of #{Enum.join(allowed, ", ")}, got: #{value}"}

      atom ->
        {:ok, atom}
    end
  end

  defp project(nil), do: {:ok, nil}

  defp project(name) do
    kinds = Argus.Project.kinds()

    case Enum.find(kinds, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "--project must be one of #{Enum.join(kinds, ", ")}, got: #{name}"}
      kind -> {:ok, kind}
    end
  end

  # `--profile` is rebar3's; a project named as something else has none.
  defp profile(nil, _project), do: :ok
  defp profile(_profile, project) when project in [nil, :rebar3], do: :ok
  defp profile(_profile, project), do: {:error, "--profile is rebar3's, not #{project}'s"}

  # `NAME=EBIN`, as the rebar3 plugin passes each application.
  defp pairs(values, flag) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case String.split(value, "=", parts: 2) do
        [name, ebin] when name != "" and ebin != "" ->
          {:cont, {:ok, acc ++ [{String.to_atom(name), ebin}]}}

        _ ->
          {:halt, {:error, "#{flag} takes NAME=EBIN, got: #{value}"}}
      end
    end)
  end

  defp analyses(_positional, _flag, true), do: {:ok, nil}
  defp analyses(positional, nil, _all), do: {:ok, positional}

  defp analyses(nil, flag, _all) do
    case flag |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [] -> {:error, "--analyses takes a comma-separated list of analyses"}
      names -> {:ok, Enum.map(names, &analysis/1)}
    end
  end

  defp analyses(_positional, _flag, _all),
    do: {:error, "name the analyses once: as arguments or with --analyses"}

  # A name is an atom the validator checks against the registry
  # (`Argus.Config.analyses/2`); the atom table is bounded by what a
  # command line holds.
  defp analysis(name), do: String.to_atom(name)

  defp non_negative(opts, keys) do
    case Enum.find(keys, &(is_integer(opts[&1]) and opts[&1] < 0)) do
      nil -> :ok
      key -> {:error, "--#{dashed(key)} must not be negative, got: #{opts[key]}"}
    end
  end

  defp dashed(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  @doc "The escript's usage."
  @spec usage() :: String.t()
  def usage do
    """
    Usage: argus [analyze] [DIR] [options]
           argus list | gc | version | help

    Analyzes the built project in DIR (default: the current directory):
    a rebar3, Gleam or erlang.mk project, or a set of ebins. argus never
    builds it: it reads the beams the build left, and says which sources
    are newer than their beams. A Mix project runs `mix argus` instead.

    Project:
      --project KIND       rebar3, gleam, erlang_mk or beams (default: found in DIR)
      --profile P          rebar3's profile (default: default)
      --root DIR           the project's root (as DIR)
      --app NAME=EBIN      an application of the program (repeatable)
      --dep NAME=EBIN      a dependency (repeatable)
      --ebin DIR           an ebin of the program, for --project beams (repeatable)
      --dep-ebin DIR       a dependency's ebin, for --project beams (repeatable)
      --state-dir DIR      where argus keeps its manifest for the project
      --config FILE        the configuration to read (rebar.config or argus.config)

    Analyses:
      --analyses A,B       these analyses (or named sets) instead of the configured ones
      --all                every analysis
      --include-deps       analyze the dependencies' modules too
      --force              ignore the manifest and recompute everything

    Output:
      --format text|json   pentiment frames on stderr (default), or JSON on stdout
      --color auto|always|never
      --fail-above N       exit 1 when there are more than N findings

    Exit status: 0 done, 1 findings over --fail-above, 2 a usage, project
    or configuration error, 3 the analyses could not run or did not finish
    (no Rust to build the engines with, an analysis that degraded).

    The blob store is $ARGUS_CACHE_DIR, else $XDG_CACHE_HOME/argus/store,
    else ~/.cache/argus/store; `argus gc` collects it.
    """
  end
end
