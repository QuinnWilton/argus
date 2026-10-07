defmodule Argus.Analysis do
  @moduledoc """
  The analysis behaviour, and the entry points for running one.

  An analysis is a module implementing this behaviour: its name, a
  FlowLog program under `priv/dl/`, the extractors whose facts the
  program reads, and its output relations. Each built-in analysis owns
  one concern — what goes wrong (`:startup`, `:mailbox`, `:races`, ...);
  mechanism, phase and proximity are columns of a relation, never
  another analysis. `concerns/0` lists them and `sets/0` names the
  groups callers run together (`:all`, `:default`, `:security`,
  `:effects`, `:otp`).

  An output relation's rows are findings, rendered by the optional
  `c:finding/2` callback, unless the relation declares `:evidence`: its
  rows are then related frames of the finding they join, rendered by
  `c:evidence/2`, or `retier: :tooling`: its rows name the modules only
  developers' tools or tests run, and every finding anchored in one
  steps down a level (`Argus.Findings.Tooling`; every built-in declares
  it, from `clientlib/tooling.dl`). A relation keys its rows
  (`t:row_key/0`) so the witnesses of one defect are one finding. `Argus.Findings` turns a
  solve's rows into findings and holds the helpers `c:finding/2`
  builds them with; a finding that rests on a prior (`Argus.Priors`) is
  marked heuristic there.

  ## Running

  - `Argus.Findings.run/2` (`Argus.run_analyses/2`) runs a selection and
    returns findings: what most callers want.
  - `run/3` (`Argus.analyze/3`) runs one analysis and returns its raw
    rows.
  - `extract_facts/3`, then `run_rules/3` per analysis, is the same run
    in two steps, for a caller that keeps the facts directory (scry,
    encore); `derive_stage0/2`, `derive_points_to/2`,
    `input_relations/1` and `filter_to_outputs/2` serve incremental
    consumers that project a directory per analysis.

  The code behind these lives in three modules, each delegated to from
  here: `Argus.Analysis.Sets` (concerns, sets and how a selection
  resolves), `Argus.Analysis.Catalog` (discovering the built-in modules
  from the `:argus_beam` application's module list, and their rules
  paths) and `Argus.Analysis.Extraction` (the facts directory: the
  pipeline, stage 0, priors).

  ## Defining a custom analysis

  Create a module that implements `@behaviour Argus.Analysis`, and build
  its findings with `Argus.Findings`' constructors (`new/4`, the `at_*`
  anchors, `related/3`, `heuristic/3`):

      defmodule MyApp.Analyses.Unused do
        @behaviour Argus.Analysis

        alias Argus.Findings

        @impl true
        def name, do: :unused

        @impl true
        def description, do: "find unused functions"

        @impl true
        def rules_file, do: "unused.dl"

        @impl true
        def extractors, do: []

        @impl true
        def output_relations do
          [
            %{
              name: :unused_function,
              fields: [{:func, :symbol, "function ID"}],
              doc: "Function that is never called."
            }
          ]
        end

        @impl true
        def finding(:unused_function, [func]) do
          Findings.new(:info, "Unused function", "Nothing calls \#{func}.",
            at: Findings.at_func(func),
            help: ["delete \#{func}, or call it"]
          )
        end
      end

  Without `finding/2`, each row is a generic `:info` finding carrying the
  relation's `doc` and the row's columns.

  The built-ins are the modules of the `:argus_beam` application, so a
  module defined elsewhere is not selectable by name. Solve its program
  with `run/3` and `{:custom, "path/to/unused.dl"}`, then turn the rows
  into findings with `Argus.Findings.build(MyApp.Analyses.Unused,
  results)`. The same `{:custom, path}` runs ad-hoc Datalog rules
  without defining a module at all.
  """

  alias Argus.Analysis.Catalog
  alias Argus.Analysis.Extraction
  alias Argus.Analysis.Sets

  # Behaviour callbacks.

  @typedoc """
  What one row of an output relation identifies.

  `key` names the columns that make a row one finding: rows agreeing on
  them are witnesses of the same defect and are deduplicated. A merged
  relation whose rows differ in kind may key each kind differently:
  `{column, %{value => key, default: key}}` picks the key by that
  column's value (the column itself always takes part).
  """
  @type row_key :: [atom()] | {atom(), %{optional(String.t()) => [atom()], default: [atom()]}}

  # `earliest` names an instruction column: of the rows a `key` folds into
  # one, the one kept is the earliest instruction there (Argus.Findings.Rows).

  @typedoc """
  An output relation whose rows are evidence for another relation's
  findings rather than findings of their own.

  `of` names the finding relation and `on` how a row joins it: a list of
  `{evidence_column, finding_column}` pairs (an atom stands for the same
  name in both). Each matching row becomes a related frame of the
  finding through the analysis's `evidence/2` callback; `limit` keeps
  the first that many frames per finding, in row order.
  """
  @type evidence :: %{
          required(:of) => atom(),
          required(:on) => [atom() | {atom(), atom()}],
          optional(:limit) => pos_integer()
        }

  @type output_relation :: %{
          required(:name) => atom(),
          required(:fields) => [Argus.Schema.field()],
          required(:doc) => String.t(),
          optional(:key) => row_key(),
          optional(:earliest) => atom(),
          optional(:evidence) => evidence(),
          optional(:retier) => :tooling
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback rules_file() :: String.t()
  @callback extractors() :: [module()]
  @callback output_relations() :: [output_relation()]

  @doc """
  Converts one output-relation row into finding attributes.

  Receives the relation name (as declared in `output_relations/0`) and the
  raw row (a list of strings, one per declared field). Implementations
  assign a severity, write title/detail prose, and attach the most precise
  anchor the row allows — see `Argus.Findings` for the construction
  helpers. Optional: analyses without it fall back to a generic
  `:info`-severity rendering of the relation's declared doc.

  Relations that carry witness columns (a call site that evidences the
  defect) can produce several rows for one logical finding — one per
  witnessing site. Such a relation declares `:key`: the field names that
  identify the finding. Rows agreeing on the key fields are deduplicated
  before conversion, and `finding/2` receives one deterministic
  representative (the lexicographically least row), so finding counts do
  not depend on how many sites witness the same defect.
  """
  @callback finding(relation :: atom(), row :: [String.t()]) :: Argus.Findings.attrs()

  @doc """
  Converts one row of an evidence relation into a related frame of the
  finding it joins (see the `:evidence` key of `t:output_relation/0`).
  """
  @callback evidence(relation :: atom(), row :: [String.t()]) :: Argus.Findings.related()

  @optional_callbacks finding: 2, evidence: 2

  # Public API types.

  @type analysis :: atom() | {:custom, Path.t()}
  @type result :: %{String.t() => [[String.t()]]}

  # ── Concerns and sets (Argus.Analysis.Sets) ─────────────────────────

  @doc "The concern vocabulary: every built-in analysis is named after one."
  @spec concerns() :: [atom()]
  defdelegate concerns(), to: Sets

  @doc """
  The named sets of analyses `Argus.run_analyses/2` accepts in place of a
  list: `:all` (every built-in but `:coverage`, which measures the
  extractor pipeline rather than the code), `:default` (what scry runs
  without configuration), `:security`, `:effects` and `:otp` (everything
  else).
  """
  @spec sets() :: %{atom() => [atom()]}
  defdelegate sets(), to: Sets

  @doc "The analyses in a named set: `{:ok, names}` or `:error`."
  @spec set(atom()) :: {:ok, [atom()]} | :error
  defdelegate set(name), to: Sets

  # ── Built-in analyses (Argus.Analysis.Catalog) ──────────────────────

  @doc "The built-in analysis names, sorted (`Argus.Analysis.Catalog.names/0`)."
  @spec builtin_analyses() :: [atom()]
  defdelegate builtin_analyses(), to: Catalog, as: :names

  @doc "The built-in analysis modules, sorted by name (`Argus.Analysis.Catalog.modules/0`)."
  @spec builtin_analysis_modules() :: [module()]
  defdelegate builtin_analysis_modules(), to: Catalog, as: :modules

  @doc """
  Looks up a built-in analysis module by name.

  Returns `{:ok, module}` or `:error` if not found.
  """
  @spec fetch_module(atom()) :: {:ok, module()} | :error
  defdelegate fetch_module(name), to: Catalog, as: :fetch

  @doc """
  Returns output relations for a named built-in analysis.

  Returns `{:ok, relations}` or `:error` if the analysis is not found.
  """
  @spec output_relations(atom()) :: {:ok, [output_relation()]} | :error
  defdelegate output_relations(name), to: Catalog

  @doc """
  The output relations of an analysis whose rows are findings: every
  output relation but the evidence ones and the one that re-tiers them
  (`retier: :tooling`).
  """
  @spec finding_relations(atom()) :: {:ok, [output_relation()]} | :error
  defdelegate finding_relations(name), to: Catalog

  # ── Extraction (Argus.Analysis.Extraction) ──────────────────────────

  @doc """
  Extracts facts from the given modules once, for one or more analyses,
  into a directory of their own (`Argus.Run.extract_facts/3`): every
  relation the analyses' producers write, stage 0's call graph, and the
  points-to stage when one of them reads it. The directory feeds
  `run_rules/3` for each of the analyses without re-extraction; the
  caller removes it (and its parent) when done.
  """
  @spec extract_facts(modules :: [atom() | String.t()], [analysis()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_facts(modules, analyses, opts \\ []),
    do: Argus.Run.extract_facts(modules, analyses, opts)

  @doc """
  Derives the stage-0 relations (the shared call graph) into an existing
  facts directory: see `Argus.Analysis.Extraction.derive_stage0/2`.
  Incremental consumers call it directly and memoize the result.
  """
  @spec derive_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  defdelegate derive_stage0(facts_dir, opts \\ []), to: Extraction

  @doc "The path to the stage-0 rules file."
  @spec stage0_rules_path() :: Path.t()
  defdelegate stage0_rules_path(), to: Extraction

  @doc "The relations stage 0 writes."
  @spec stage0_relations() :: [String.t()]
  defdelegate stage0_relations(), to: Extraction

  @doc """
  Derives the points-to stage (which process a pid can be) into a facts
  directory stage 0 has been derived into: see
  `Argus.Analysis.Extraction.derive_points_to/2`. Incremental consumers
  call it directly and memoize the result.
  """
  @spec derive_points_to(Path.t(), keyword()) :: :ok | {:error, term()}
  defdelegate derive_points_to(facts_dir, opts \\ []), to: Extraction

  @doc "The path to the points-to stage's rules file."
  @spec points_to_rules_path() :: Path.t()
  defdelegate points_to_rules_path(), to: Extraction

  @doc "The path to the bounded points-to stage's rules file."
  @spec points_to_bounded_rules_path() :: Path.t()
  defdelegate points_to_bounded_rules_path(), to: Extraction

  @doc "The relations the points-to stage writes."
  @spec points_to_relations() :: [String.t()]
  defdelegate points_to_relations(), to: Extraction

  # ── Solving ─────────────────────────────────────────────────────────

  @doc """
  Runs an analysis against the given modules, on the query graph
  (`Argus.Run.analyze/3`).

  Returns `{:ok, results}` where results is a map of relation name to
  list of rows, sorted. Each row is a list of strings.

  Takes `Argus.Findings.run/2`'s options but `:analyses`; the batch
  pipeline's went with it in 0.20 and raise (`Argus.Run.check_options!/1`).
  """
  @spec run(modules :: [atom() | String.t()], analysis(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(modules, analysis, opts \\ []), do: Argus.Run.analyze(modules, analysis, opts)

  @doc """
  The relations an analysis actually reads, as FlowLog resolves them.

  Read from the program's manifest (`Argus.FlowLog.manifest/2`), which
  FlowLog's front end and planner produce after pruning every relation
  no output reaches: the source over-approximates (declared inputs that
  are never read survive in it), and following `.include` by hand
  under-approximates. The manifest's inputs are the relations the
  engine genuinely loads.

  Incremental consumers use this to project a per-analysis fact directory,
  so an analysis only re-solves when a relation it truly reads has moved.

  Returns `{:ok, [relation_name]}` or `{:error, reason}`.
  """
  @spec input_relations(analysis(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(analysis, opts \\ []) do
    with {:ok, rules_path} <- Catalog.rules_path(analysis) do
      Argus.FlowLog.input_relations(rules_path, Keyword.take(opts, [:progress]))
    end
  end

  @doc """
  Runs a single analysis's Datalog rules against an existing facts directory.

  The facts directory must contain `.facts` files for every relation the
  compiled program reads as input — `extract_facts/3` guarantees this when the
  analysis was included in its analyses list.

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec run_rules(Path.t(), analysis(), keyword()) :: {:ok, result()} | {:error, term()}
  def run_rules(facts_dir, analysis, opts \\ []) do
    with {:ok, rules_path} <- Catalog.rules_path(analysis),
         :ok <- Extraction.ensure_stage0(facts_dir, opts),
         :ok <- Extraction.ensure_points_to(facts_dir, [analysis], opts) do
      Argus.FlowLog.run(facts_dir, rules_path, opts)
    end
  end

  @doc """
  Restricts raw engine results to the relations a built-in analysis
  declares as its outputs.

  Intermediate clientlib relations (`call_reachable`, `sync_dep`, ...) are
  dropped. Custom analyses and unknown names pass through unchanged — there
  is no declaration to filter against.
  """
  @spec filter_to_outputs(result(), analysis()) :: result()
  def filter_to_outputs(results, {:custom, _path}), do: results

  def filter_to_outputs(results, name) when is_atom(name) do
    case output_relations(name) do
      {:ok, relations} ->
        allowed = Enum.map(relations, &Atom.to_string(&1.name))
        Map.take(results, allowed)

      :error ->
        results
    end
  end
end
