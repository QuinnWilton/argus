defmodule Argus.Graph do
  @moduledoc """
  Argus as a roux query graph: extraction, the shared stages, every
  solve and the findings, each a memoized query keyed by what it read,
  so a run computes again only what an edit reached.

  ## The graph

      program(p) ─ beam(k) … [inputs: Argus.Graph.Inputs]
           │
      module_facts(k)            per-module packs in the blob store,
           │                     each producer's found by its trace
      module_semantic(k)         ── cutoff: line_info left out
           │
      program_relations(p)       a Merkle digest per relation, over the
           │                     program's modules as one fan-out
      relation({p, r})           ── cutoff: per relation
           │
      stage({p, :stage0})  ─ stage_output({p, :stage0, f})    ── cutoff
      stage({p, :points_to}) ─ stage_output({p, :points_to, f}) ── cutoff
           │
      analysis_inputs({p, a}) ─ program_digest(a) ← program_io(a) ← program_files(a)
           │
      solve({p, a})              one Souffle solve, kept by its key
           │
      findings({p, a})           line-free (store: :blob)
           │
      located({p, a})            placed: line_table(k), declaration_line(k)

  A program is any term naming a set of beams (`:project` for a Mix
  project, `:batch` for `Argus.run_analyses/2`); one database can hold
  several, sharing every module's facts.

  ## What a query is keyed by

  By the inputs it reads (`Argus.Graph.Inputs`), the queries it
  demands, and the code it runs: each query's code version is the
  digest of the code its module reaches (`Roux.Code`), so the queries
  are split into role modules whose closures are each as tight as their
  job. An edit to an extractor moves `module_facts` alone; to the
  findings' prose, `findings` alone; to a rule, the programs that
  include it (through `dl_tree`); to the driver, the report or the
  config, nothing. The schema's modules are data, left out of every
  closure: a query depends on the entries it read instead
  (`Argus.Graph.Reads`), and on the specs it read from the code path.
  `Argus.Graph.CodeClosureTest` runs each role and fails if it executes
  code outside its closure.

  ## Storage

  Facts stay text: each module's rows are packs in a `Roux.Blob` store,
  a relation's file is made only when a solve that is not kept needs it,
  and a solve is kept in the store's action cache by the digests of
  what it reads. A frontend opens a session over a store (`open/1`),
  whose manifest keeps the graph between runs; a run without a manifest
  keeps nothing but the store.
  """

  alias Argus.Graph.{Environment, Priors, Programs}
  alias Roux.Blob
  alias Roux.Input

  @modules [
    Argus.Graph.Inputs,
    Argus.Graph.Frontend,
    Argus.Graph.Reads,
    Argus.Graph.Code,
    Argus.Graph.Extraction,
    Argus.Graph.Relations,
    Argus.Graph.Programs,
    Argus.Graph.Solve,
    Argus.Graph.Findings,
    Argus.Graph.Locate
  ]

  @doc "The modules of the graph's queries and inputs, to register (`Roux.Session.open/1`)."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc """
  The analyses the frontends run unconfigured: argus's `:default` set.
  """
  @spec default_analyses() :: [atom()]
  def default_analyses do
    {:ok, analyses} = Argus.Analysis.set(:default)
    analyses
  end

  @doc """
  Opens a session over the graph (`Roux.Session.open/1`).

  ## Options

    * `:store` — the blob store: a `Roux.Blob`, the root of one, or nil
      for `store/0`'s;
    * `:manifest` — where the graph is kept between runs, or nil (the
      default) to keep nothing but the store;
    * `:force` — start cold, ignoring the manifest;
    * `:frontend` — the module answering the frontend contract's queries
      (`Argus.Graph.Frontend`'s, by name) in its place: a frontend that
      compiles in memory. What it reads of a module's specs is tracked
      through the `beam` input of the module's path, or the `app_code`
      of its directory (`Argus.Graph.Reads`): it sets one of them for
      every beam it puts on the code path.
  """
  @spec open(keyword()) :: Roux.Session.t()
  def open(opts \\ []) do
    opts = Keyword.validate!(opts, store: nil, manifest: nil, force: false, frontend: nil)

    modules =
      case opts[:frontend] do
        nil -> @modules
        frontend -> List.replace_at(@modules, 1, frontend)
      end

    Roux.Session.open(
      modules: modules,
      blob: opts[:store] || store(),
      manifest: opts[:manifest],
      force: opts[:force]
    )
  end

  @doc """
  The blob store a run keeps its facts and solves in: a temporary one
  under `ARGUS_NO_CACHE`, removed when its session closes; else the one
  `ARGUS_CACHE_DIR` names, else `$XDG_CACHE_HOME/argus/store`, else
  `~/.cache/argus/store`. Shared by every run on the machine, every
  worktree and every VM: entries are immutable and named by content.
  """
  @spec store() :: Blob.t()
  def store do
    if Argus.Cache.enabled?(), do: Blob.open!(store_root()), else: Blob.temporary()
  end

  @doc "The root of `store/0`'s store (see there)."
  @spec store_root() :: Path.t()
  def store_root do
    cond do
      dir = System.get_env("ARGUS_CACHE_DIR") -> Path.expand(dir)
      dir = System.get_env("XDG_CACHE_HOME") -> Path.join([dir, "argus", "store"])
      true -> Path.expand("~/.cache/argus/store")
    end
  end

  @doc """
  Sets what the graph runs on beyond the program's beams: the solver
  (nil when there is none, and nothing is solved), the code path's
  index and each directory's stamp, the Datalog trees the programs are
  read from, and the project's root. Returns whether any of them moved.

  ## Options

    * `:project_root` — default `File.cwd!/0`;
    * `:specs_source` — where the specs of the modules the program calls
      are read from (`Argus.Specs.Source`), default nil: the VM's code
      path;
    * `:trees` — the Datalog trees besides argus's own (a custom
      program's directory);
    * `:souffle_timeout` — milliseconds a solve may run.
  """
  @spec set_environment(Roux.Database.t(), keyword()) :: boolean()
  def set_environment(db, opts \\ []) do
    source = Keyword.get(opts, :specs_source)
    index = Environment.code_index(source)
    trees = Enum.uniq([Programs.tree(:stage0) | Keyword.get(opts, :trees, [])])

    [
      set(db, :solver, :all, Environment.solver(db.blob, opts)),
      set(db, :specs_source, :all, source),
      set(db, :code_index, :all, index),
      set(db, :project_root, :all, Keyword.get_lazy(opts, :project_root, &File.cwd!/0))
      | Enum.map(index, fn {dir, name} -> set(db, :app_code, name, Environment.app_code(dir)) end) ++
          Enum.map(trees, &set(db, :dl_tree, &1, Programs.tree_digests(&1)))
    ]
    |> Enum.any?()
  end

  @doc """
  Sets the beams of `program`: each key's `beam` input from its file (or
  its bytes), and the program's sorted keys. A beam key is the absolute
  path of a `.beam` file, or `{:data, digest}` for a beam held in memory
  (`beam_key/1`). Returns the keys.
  """
  @spec set_program(Roux.Database.t(), term(), [Path.t() | binary()]) :: [term()]
  def set_program(db, program, beams) do
    keys =
      for beam <- beams do
        {key, value} = beam_input(beam)
        :ok = Input.set(db, :beam, key, value)
        key
      end

    keys = keys |> Enum.uniq() |> Enum.sort()
    :ok = Input.set(db, :program, program, keys)
    keys
  end

  @doc """
  A beam's key and its `beam` input: `{path, %{hash: digest}}` for a
  file, `{{:data, digest}, %{hash: digest, data: bytes}}` for bytes.
  The digest is of the beam without the chunks extraction never reads
  (`Roux.Code.canonical_beam/1`).
  """
  @spec beam_input(Path.t() | binary()) :: {term(), map()}
  def beam_input(<<"FOR1", _::binary>> = data) do
    hash = hash(data)
    {{:data, hash}, %{hash: hash, data: data}}
  end

  def beam_input(path) when is_binary(path) do
    path = Path.expand(path)
    {path, %{hash: path |> File.read!() |> hash()}}
  end

  @doc "The digest a beam's `beam` input holds for its bytes."
  @spec hash(binary()) :: String.t()
  def hash(bytes) do
    :sha256 |> :crypto.hash(Roux.Code.canonical_beam(bytes)) |> Base.encode16(case: :lower)
  end

  @doc "Sets the program's priors (`Argus.Graph.Priors.sync/3`)."
  @spec set_priors(Roux.Database.t(), term(), Priors.config()) :: :ok
  defdelegate set_priors(db, program, config), to: Priors, as: :sync

  @doc """
  Each of `analyses` placed (`Argus.Graph.Locate`'s `located`), solved
  side by side: `{:ok, [Argus.Located]}` or why the analysis degraded.
  An analysis that raises — rules and code out of step, a bug — is
  degraded with `{:crashed, banner}`, and the others still report.

  `:concurrency` bounds how many analyses solve at once (default: the
  schedulers).
  """
  @spec located(Roux.Database.t(), term(), [atom()], keyword()) ::
          %{optional(atom()) => {:ok, [Argus.Located.t()]} | {:error, term()}}
  def located(db, program, analyses, opts \\ []) do
    analyses
    |> Task.async_stream(&{&1, located_one(db, program, &1)},
      max_concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
      ordered: true,
      # Each solve is bounded by the solver's own timeout.
      timeout: :infinity
    )
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp located_one(db, program, analysis) do
    Argus.Graph.Locate.located(db, {program, analysis})
  rescue
    exception -> {:error, {:crashed, Exception.format_banner(:error, exception, __STACKTRACE__)}}
  end

  # Sets an input; true when its value moved.
  defp set(db, input, key, value) do
    moved? = Input.fetch(db, input, key) != {:ok, value}
    :ok = Input.set(db, input, key, value)
    moved?
  end
end
