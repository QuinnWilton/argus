defmodule Argus.Project do
  @moduledoc """
  A built project, as argus analyzes it: where it is, the ebins of the
  program and of its dependencies, and where argus keeps its state for
  it.

  Each build tool has an adapter that finds them (`load/3`):

  | Kind | Program | Dependencies | State |
  |---|---|---|---|
  | `:mix` | the compile path (in the VM Mix runs) | the build's other ebins | Mix's manifest path |
  | `:rebar3` | the root app and `apps/*`, as one program | `_build/<profile>/lib/*/ebin`, the rest | `_build/<profile>/argus` |
  | `:gleam` | `build/dev/erlang/<package>/ebin` | the other packages there | `build/argus` |
  | `:erlang_mk` | `ebin/` | `deps/*/ebin` | `.erlang.mk/argus` |
  | `:beams` | `--ebin DIR`s | `--dep-ebin DIR`s | `.argus` |

  Explicit ebins (`apps:`/`deps:` as `{name, ebin}`, the escript's
  `--app N=EBIN` and `--dep N=EBIN`) take the place of what an adapter
  would find: the rebar3 plugin passes the exact ones rebar3 built.

  The program's modules are analyzed; a dependency's are analyzed too
  with `include_deps`, and otherwise only read for the specs of the
  functions the program calls (`Argus.Specs.Source`). Argus never puts
  a project's ebins on the VM's code path, so a dependency can never
  collide with a copy the escript carries.

  argus does not build a project. An adapter names the command that does
  (`build`), and `stale/1` lists the sources newer than their beams, for
  a frontend to say so: the findings are about the code as last built.
  """

  @enforce_keys [:kind, :root, :apps, :deps, :state_dir]
  defstruct [:kind, :root, :apps, :deps, :state_dir, build: nil, sources: []]

  @typedoc "A build tool argus knows."
  @type kind :: :mix | :rebar3 | :gleam | :erlang_mk | :beams

  @typedoc "An application and the directory its beams are in."
  @type ebin :: {atom(), Path.t()}

  @typedoc """
  A project. Paths are absolute. `build` is the command that builds it
  (nil when argus does not know one); `sources` pairs each of the
  program's source directories with its ebin and its language, for
  `stale/1`.
  """
  @type t :: %__MODULE__{
          kind: kind(),
          root: Path.t(),
          apps: [ebin()],
          deps: [ebin()],
          state_dir: Path.t(),
          build: String.t() | nil,
          sources: [{Path.t(), Path.t(), :erlang | :gleam}]
        }

  @typedoc """
  Options of `load/3`: `profile:` (rebar3's, default `"default"`),
  `apps:` and `deps:` (explicit `{name, ebin}` pairs), `ebins:` and
  `dep_ebins:` (directories, for `:beams`), `state_dir:`.
  """
  @type option ::
          {:profile, String.t()}
          | {:apps, [ebin()]}
          | {:deps, [ebin()]}
          | {:ebins, [Path.t()]}
          | {:dep_ebins, [Path.t()]}
          | {:state_dir, Path.t()}

  @doc "Whether the directory holds a project of this adapter's kind."
  @callback detect?(root :: Path.t()) :: boolean()

  @doc "The project rooted at `root`, or why it cannot be analyzed."
  @callback load(root :: Path.t(), [option()]) :: {:ok, t()} | {:error, String.t()}

  @adapters [
    mix: Argus.Project.Mix,
    rebar3: Argus.Project.Rebar3,
    gleam: Argus.Project.Gleam,
    erlang_mk: Argus.Project.ErlangMk,
    beams: Argus.Project.Beams
  ]

  @doc "Every kind, in the order `detect/1` tries them."
  @spec kinds() :: [kind()]
  def kinds, do: Keyword.keys(@adapters)

  @doc "The adapter of `kind`."
  @spec adapter(kind()) :: module()
  def adapter(kind), do: Keyword.fetch!(@adapters, kind)

  @doc """
  The kind of project at `root`, from the files its build tool keeps
  there (`mix.exs`, `rebar.config`, `gleam.toml`, `erlang.mk`), or
  `:error`. A directory of bare beams is never detected: it is named.
  """
  @spec detect(Path.t()) :: {:ok, kind()} | :error
  def detect(root) do
    Enum.find_value(@adapters, :error, fn {kind, adapter} ->
      kind != :beams and adapter.detect?(root) and {:ok, kind}
    end)
  end

  @doc "The project of `kind` at `root` (`t:option/0`)."
  @spec load(kind(), Path.t(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def load(kind, root, opts \\ []), do: adapter(kind).load(Path.expand(root), opts)

  @doc """
  The program's sources that are newer than their beams, or have none:
  the findings are about the code as last built. Relative to the root.
  """
  @spec stale(t()) :: [Path.t()]
  def stale(%__MODULE__{root: root, sources: sources}) do
    for {src, ebin, language} <- sources,
        source <- src |> Path.join("**/*") |> Path.wildcard() |> Enum.sort(),
        module = module_of(language, Path.relative_to(source, src)),
        module != nil,
        stale?(source, Path.join(ebin, module <> ".beam")) do
      Path.relative_to(source, root)
    end
  end

  # The module a source file compiles to: an Erlang module (or a yecc or
  # leex grammar, which generates one) is named by its file; a Gleam
  # module by its path, with `@` for `/`.
  defp module_of(:erlang, relative) do
    if Path.extname(relative) in [".erl", ".yrl", ".xrl"],
      do: Path.basename(relative, Path.extname(relative))
  end

  defp module_of(:gleam, relative) do
    if Path.extname(relative) == ".gleam",
      do: relative |> Path.rootname() |> String.replace("/", "@")
  end

  defp stale?(source, beam) do
    case {File.stat(source, time: :posix), File.stat(beam, time: :posix)} do
      {{:ok, %{type: :regular, mtime: src}}, {:ok, %{mtime: built}}} -> src > built
      {{:ok, %{type: :regular}}, {:error, _}} -> true
      _ -> false
    end
  end

  @doc """
  The explicit ebins of `opts` under `key` (`apps:`, `deps:`), made
  absolute against `root`, or nil when none were given.
  """
  @spec explicit([option()], :apps | :deps, Path.t()) :: [ebin()] | nil
  def explicit(opts, key, root) do
    case Keyword.get(opts, key) do
      nil -> nil
      pairs -> for {name, ebin} <- pairs, do: {name, Path.expand(ebin, root)}
    end
  end

  @doc """
  Each `lib/<app>/ebin` under `lib`, named by its directory, sorted,
  less `except`.
  """
  @spec lib_ebins(Path.t(), [atom()]) :: [ebin()]
  def lib_ebins(lib, except \\ []) do
    for ebin <- lib |> Path.join("*/ebin") |> Path.wildcard() |> Enum.sort(),
        File.dir?(ebin),
        name = ebin |> Path.dirname() |> Path.basename() |> String.to_atom(),
        name not in except,
        do: {name, ebin}
  end

  @doc """
  `:ok` when every app's ebin holds beams, else the error naming the
  ones that do not and the command that builds them.
  """
  @spec require_beams([ebin()], Path.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def require_beams([], root, build) do
    {:error, "no application to analyze in #{root}" <> run_first(build)}
  end

  def require_beams(apps, root, build) do
    case Enum.reject(apps, fn {_name, ebin} -> beams?(ebin) end) do
      [] ->
        :ok

      missing ->
        listed =
          Enum.map_join(missing, ", ", fn {name, ebin} ->
            "#{name} (#{Path.relative_to(ebin, root)})"
          end)

        {:error, "no beams for #{listed}" <> run_first(build)}
    end
  end

  defp beams?(ebin), do: ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.any?()

  defp run_first(nil), do: ""
  defp run_first(build), do: "; build it first (`#{build}`)"
end
