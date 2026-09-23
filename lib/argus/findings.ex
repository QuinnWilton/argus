defmodule Argus.Findings do
  @moduledoc """
  Structured findings from running analyses in-process.

  `run/2` (exposed as `Argus.run_analyses/2`) extracts facts once, evaluates
  each selected analysis's Datalog rules against the shared facts directory,
  and converts every output-relation row into a finding map with a severity,
  human-readable prose, and the most precise anchor the row allows:

  - `instr` — an `Argus.InstrId` when the row carries an instruction ID.
  - `mfa` — `{module, function, arity}` when the row carries a function ID
    (or names a well-known callback such as `init/1`).
  - `module` — always set when the row names a module at all.

  ## Degradation

  The promise is degrade-, never crash-, and never silently:

  - Souffle missing from PATH → `{:error, :souffle_not_found}` up front.
  - Fact extraction failing (unknown module, unreadable `.beam`) →
    `{:error, reason}` — nothing could have run.
  - A single analysis erroring (rules bug, Souffle timeout) → a
    `degraded` entry naming the analysis and why, while every other
    analysis still runs and reports.
  - A finding builder raising on a row it did not expect → that row is
    reported with its raw columns (a generic finding, or a generic frame
    for an evidence row, whose help says so) and the analysis gets a
    `degraded` entry as well as its `ran` one; every other row of the
    concern reports as usual.
  - An extraction step failing on one module (an extractor raising on a
    shape it did not expect, a module outliving the per-module timeout)
    → an `extraction_errors` entry naming the module, the step and the
    error. The analyses still run over everything that was extracted,
    so they report, but a finding that needed the lost rows is missing:
    a consumer shows these beside the findings rather than as a failed
    analysis.

  Anchor parsing and the atoms it makes: `Argus.Findings.Anchor`.
  """

  alias Argus.Analysis
  alias Argus.Analysis.Sets
  alias Argus.Findings.Anchor
  alias Argus.Findings.Build
  alias Argus.Findings.Names
  alias Argus.Findings.Rows
  alias Argus.InstrId
  alias Argus.Souffle

  defstruct findings: [], ran: [], degraded: [], extraction_errors: []

  @typedoc "Finding severity, in decreasing order of urgency."
  @type severity :: :error | :warning | :info

  @typedoc "Code location attached to a finding, most precise field wins (`Argus.Findings.Anchor`)."
  @type anchor :: Anchor.t()

  @typedoc """
  The source block an anchor sits in, for a consumer with the source to
  draw the span to when the bytecode gives no end: `:guard` (the
  `rescue`/`catch`/`after` clauses that guard the anchored call, to
  their `end`), `:receive` (the `receive do ... end` the anchor opens),
  `:clause` (the function clause the anchor heads, to its `end`),
  `:function` (every clause of the anchored function).

  Bytecode cannot tell a `rescue` from a `catch` — both are a `try`
  handler of class `:error` — so prose about a guard says `{guard}`
  where the keyword goes, and a consumer with the source puts the word
  it finds there (`Scry.SourceAnchor.guard_keyword/2`); one without
  reads it as `handler`.
  """
  @type block :: :guard | :receive | :clause | :function

  @typedoc """
  A labelled secondary location (sibling, supervisor, callee, ...).
  `to_instr` closes a span: the frame covers the lines from `instr` to
  it (a call and the catch that guards it). `at_source` refines the
  frame's line from the source as a finding's does (see `new/4`).
  """
  @type related :: %{
          label: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil,
          to_instr: InstrId.t() | nil,
          to_block: block() | nil,
          at_source: String.t() | nil
        }

  @typedoc """
  Where a finding's evidence came from: `:structural` when every premise
  is a fact of the bytecode, `:heuristic` when a prior (`Argus.Priors`)
  supplied one. A heuristic finding carries the prior's probability in
  thousandths as `confidence`.
  """
  @type provenance :: :structural | :heuristic

  @typedoc "What an analysis module's `finding/2` callback returns."
  @type attrs :: %{
          severity: severity(),
          title: String.t(),
          detail: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil,
          at_label: String.t() | nil,
          at_source: String.t() | nil,
          to_instr: InstrId.t() | nil,
          to_block: block() | nil,
          help: [String.t()],
          related: [related()],
          provenance: provenance(),
          confidence: 0..1000 | nil
        }

  @typedoc """
  A finding: `attrs` plus the analysis that produced it. `concern` is the
  same analysis: the two differed only while retired names could be
  selected (0.17 to 0.19), and `concern` stays for the readers written
  then.
  """
  @type finding :: %{
          analysis: atom(),
          concern: atom(),
          severity: severity(),
          title: String.t(),
          detail: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil,
          at_label: String.t() | nil,
          at_source: String.t() | nil,
          to_instr: InstrId.t() | nil,
          to_block: block() | nil,
          help: [String.t()],
          related: [related()],
          provenance: provenance(),
          confidence: 0..1000 | nil
        }

  @typedoc "Per-analysis run record for analyses that completed."
  @type ran_entry :: %{
          analysis: atom(),
          duration_ms: non_neg_integer(),
          finding_count: non_neg_integer()
        }

  @typedoc "Per-analysis degradation note for analyses that did not complete."
  @type degradation :: %{analysis: atom(), reason: term(), detail: String.t()}

  @typedoc """
  An extraction step that failed on a module (the `extraction_error`
  relation): `module` is nil when not even the beam's name could be read,
  and `source` is then its path. `step` is the extractor's module name or
  a pipeline stage (`"pipeline"` when the module lost all its facts);
  `reason` is the error on one line.
  """
  @type extraction_error :: %{
          module: module() | nil,
          source: String.t(),
          step: String.t(),
          reason: String.t()
        }

  @type t :: %__MODULE__{
          findings: [finding()],
          ran: [ran_entry()],
          degraded: [degradation()],
          extraction_errors: [extraction_error()]
        }

  @severity_rank %{error: 0, warning: 1, info: 2}
  @blocks [:guard, :receive, :clause, :function]

  @severities Map.keys(@severity_rank)

  # ── Running ────────────────────────────────────────────────────────

  @doc """
  Runs analyses against the given modules and returns structured findings.

  `modules` is a list of module atoms or paths to `.beam` files, exactly
  as `Argus.analyze/3` accepts.

  ## Options

  - `:analyses` — a named set or a list of analysis names (default
    `:all`). The sets are `Argus.Analysis.sets/0`'s: `:all` (every
    built-in analysis except `:coverage`, which measures the extractor
    pipeline rather than the analyzed code), `:default` (what scry runs
    unconfigured), `:security`, `:effects` and `:otp`. A name is a
    concern (`:startup`, `:mailbox`, ...); an unknown name is
    `{:error, {:unknown_analysis, name}}`, anything else
    `{:error, {:invalid_analyses, value}}`.
  - `:facts_dir` — a directory `Argus.Analysis.extract_facts/3` already
    wrote for these modules, to evaluate without extracting again. The
    caller owns it; without this option the run extracts into a
    temporary directory and removes it afterwards.
  - `:concurrency` — parallel Souffle solves (default: the scheduler
    count, capped at 4; each solve holds its own copy of the call graph's
    closure). Extraction always runs at scheduler width.
  - All other `Argus.Analysis.run/3` options (`:extractors`,
    `:souffle_bin`, `:souffle_timeout`, ...) pass through.

  Returns `{:ok, %Argus.Findings{}}` or `{:error, reason}` — see the
  moduledoc for the degradation contract.
  """
  @spec run(modules :: [atom() | String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def run(modules, opts \\ []) when is_list(modules) and is_list(opts) do
    {selection, opts} = Keyword.pop(opts, :analyses, :all)

    with {:ok, requests} <- Sets.resolve(selection),
         :ok <- ensure_souffle(opts) do
      evaluate(modules, requests, opts)
    end
  end

  defp evaluate(_modules, [], _opts), do: {:ok, %__MODULE__{}}

  defp evaluate(modules, requests, opts) do
    names = Enum.map(requests, & &1.name())

    case facts_dir(modules, names, opts) do
      {:ok, facts_dir, owned?} ->
        try do
          outcomes =
            requests
            |> Task.async_stream(&run_one(&1, facts_dir, opts),
              max_concurrency: Keyword.get(opts, :concurrency, default_solve_concurrency()),
              ordered: true,
              # Souffle.run bounds each evaluation with :souffle_timeout, so the
              # task itself never needs a second, racing deadline.
              timeout: :infinity
            )
            |> Enum.flat_map(fn {:ok, outcomes} -> outcomes end)

          {:ok, %{collect(outcomes) | extraction_errors: extraction_errors(facts_dir)}}
        after
          if owned?, do: File.rm_rf(Path.dirname(facts_dir))
        end

      # Stage 0 (the shared call graph) is a Souffle evaluation like any
      # other, and Souffle trouble is degradation, not a crash — the same
      # contract a per-analysis solve gets. Because every analysis reads
      # its output, a stage-0 failure grounds all of them, so each one
      # degrades with the underlying reason rather than the whole call
      # collapsing into an opaque error.
      {:error, {:stage0, reason}} ->
        {:ok,
         collect(
           for mod <- requests, name = mod.name() do
             {:degraded,
              %{analysis: name, reason: reason, detail: degradation_detail(name, reason)}}
           end
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp facts_dir(modules, names, opts) do
    case Keyword.fetch(opts, :facts_dir) do
      {:ok, dir} ->
        {:ok, dir, false}

      :error ->
        with {:ok, dir} <- Analysis.extract_facts(modules, names, opts), do: {:ok, dir, true}
    end
  end

  @doc """
  The extraction errors recorded in a facts directory
  (`Argus.Analysis.extract_facts/3` writes them as `extraction_error`),
  in the order extraction met them. A directory without the file has
  none.
  """
  @spec extraction_errors(Path.t()) :: [extraction_error()]
  def extraction_errors(facts_dir) do
    case File.read(Path.join(facts_dir, "extraction_error.facts")) do
      {:ok, content} ->
        for [mod, step, reason] <- Argus.Tsv.decode(content) do
          %{module: Anchor.module_atom(mod), source: mod, step: step, reason: reason}
        end

      {:error, _} ->
        []
    end
  end

  # One solve per analysis module; every row is a finding under the
  # analysis's own name.
  defp run_one(mod, facts_dir, opts) do
    name = mod.name()
    {elapsed_us, result} = :timer.tc(fn -> Analysis.run_rules(facts_dir, name, opts) end)
    duration_ms = div(elapsed_us, 1000)

    case result do
      {:ok, results} ->
        try do
          {findings, failures} = Build.build(mod, results)

          ran =
            {:ran, %{analysis: name, duration_ms: duration_ms, finding_count: length(findings)},
             findings}

          [ran | row_degradation(name, failures)]
        rescue
          exception ->
            [
              {:degraded,
               %{
                 analysis: name,
                 reason: {:finding_builder_crashed, exception},
                 detail:
                   "The #{name} analysis ran, but converting its results to findings " <>
                     "crashed: #{Exception.message(exception)}. This is a bug in Argus."
               }}
            ]
        end

      {:error, reason} ->
        [{:degraded, %{analysis: name, reason: reason, detail: degradation_detail(name, reason)}}]
    end
  end

  # Each solve is a Souffle process holding its own copy of the call
  # graph's closure — hundreds of megabytes on a large project, and it
  # scales with the project rather than the machine. Extraction is cheap
  # per task and runs at scheduler width; solves are capped so the peak
  # stays bounded.
  defp default_solve_concurrency, do: min(System.schedulers_online(), 4)

  defp collect(outcomes) do
    findings =
      outcomes
      |> Enum.flat_map(fn
        {:ran, _entry, findings} -> findings
        {:degraded, _note} -> []
      end)
      |> Enum.sort_by(fn finding ->
        {Map.fetch!(@severity_rank, finding.severity), finding.analysis, finding.title,
         finding.detail}
      end)

    ran = for {:ran, entry, _findings} <- outcomes, do: entry
    degraded = for {:degraded, note} <- outcomes, do: note

    %__MODULE__{findings: findings, ran: ran, degraded: degraded}
  end

  @doc """
  Builds an analysis's findings from its solved output relations.

  `results` maps relation names (strings) to rows. Rows of a relation
  with a `:key` are deduplicated to one per finding; rows of an evidence
  relation become related frames of the finding they join instead of
  findings. Embedders that solve the rules themselves (scry, planchette)
  build through this so their findings equal `run/2`'s field for field.

  Relations the analysis does not declare as outputs (the intermediate
  relations a custom program also writes, say) are ignored, so the raw
  result of a solve can be passed as it is.
  """
  @spec build(module(), %{String.t() => [[String.t()]]}) :: [finding()]
  def build(mod, results) when is_atom(mod) and is_map(results) do
    {findings, _failures} = Build.build(mod, results)
    findings
  end

  defp row_degradation(_name, []), do: []

  defp row_degradation(name, [first | _] = failures) do
    [
      {:degraded,
       %{
         analysis: name,
         reason: {:finding_builder_crashed, first.exception},
         detail:
           "The #{name} analysis ran, but its finding builder crashed on " <>
             "#{length(failures)} row(s), first a #{first.relation} row: " <>
             "#{Exception.message(first.exception)}. Those rows are reported with " <>
             "their raw columns; every other finding is as usual. This is a bug in Argus."
       }}
    ]
  end

  @doc """
  Deduplicates a relation's rows down to one per logical finding:
  `Argus.Findings.Rows.dedupe/2`. Embedders that count rows themselves
  (encore, planchette) go through it, or their counts drift from
  `run/2`'s.
  """
  @spec dedupe_rows(Analysis.output_relation(), [[String.t()]]) :: [[String.t()]]
  defdelegate dedupe_rows(relation, rows), to: Rows, as: :dedupe

  defp degradation_detail(name, :souffle_timeout) do
    "The #{name} analysis timed out in Souffle and was skipped. " <>
      "Raise :souffle_timeout to include it."
  end

  defp degradation_detail(name, {:souffle_error, exit_code, _output}) do
    "The #{name} analysis failed: Souffle exited with status #{exit_code}."
  end

  defp degradation_detail(name, reason) do
    "The #{name} analysis did not run: #{inspect(reason)}."
  end

  defp ensure_souffle(opts) do
    cond do
      # An explicit binary is the caller's responsibility; Souffle.run
      # reports per-analysis errors if it turns out to be unusable.
      Keyword.has_key?(opts, :souffle_bin) -> :ok
      Souffle.available?() -> :ok
      true -> {:error, :souffle_not_found}
    end
  end

  # ── Finding construction (used by analysis modules' finding/2) ─────

  @doc """
  Builds finding attributes.

  `opts`:

  - `:at` — an anchor from `at_instr/1`, `at_func/1`, `at_module/1`, or
    `at_mfa/3` (default: no anchor).
  - `:at_label` — what the anchor line IS, for renderers that excerpt the
    source ("supervision tree defined here"), so the annotation does not
    just repeat the title (default: `nil`).
  - `:to` — an anchor whose instruction closes the primary span: the
    finding covers the lines from `:at` to it, as one bracket, for a
    call and the catch that guards it (default: no span).
  - `:to_block` — the source block the anchor sits in (`t:block/0`), for
    a consumer with the source to close the span by when the bytecode
    gives no end — a catch whose bodies are literals has no line of its
    own (default: `nil`).
  - `:at_source` — a source fragment that carries the anchor the last
    step bytecode cannot: a consumer holding the source moves the anchor
    to the first line at or after the anchor's line that contains the
    fragment as a whole token. Every function an Ecto schema generates
    carries the `schema do` line, so the field's own line is only in the
    source; `":api_key"` names it. Consumers without the source ignore
    it (default: `nil`).
  - `:help` — resolution guidance, one string per suggestion, rendered by
    consumers as help trailers. Say what to change and toward what, in
    the row's own terms (default: `[]`).
  - `:related` — list of `related/2` entries (default: `[]`).
  - `:provenance` — `:structural` (default) or `:heuristic`, see `t:provenance/0`.
  - `:confidence` — a prior's probability in thousandths, for a heuristic
    finding (default: `nil`).
  """
  @spec new(severity(), String.t(), String.t(), keyword()) :: attrs()
  def new(severity, title, detail, opts \\ [])
      when severity in @severities and is_binary(title) and is_binary(detail) do
    anchor = Keyword.get(opts, :at, Anchor.empty())
    at_label = Keyword.get(opts, :at_label)
    at_source = Keyword.get(opts, :at_source)
    to_instr = Keyword.get(opts, :to, Anchor.empty()).instr
    to_block = Keyword.get(opts, :to_block)
    help = Keyword.get(opts, :help, [])
    provenance = Keyword.get(opts, :provenance, :structural)
    confidence = Keyword.get(opts, :confidence)

    unless is_nil(at_label) or is_binary(at_label) do
      raise ArgumentError, ":at_label must be a string, got: #{inspect(at_label)}"
    end

    unless is_nil(at_source) or (is_binary(at_source) and at_source != "") do
      raise ArgumentError,
            ":at_source must be a non-empty string, got: #{inspect(at_source)}"
    end

    unless to_block in [nil | @blocks] do
      raise ArgumentError,
            ":to_block must be one of #{inspect(@blocks)}, got: #{inspect(to_block)}"
    end

    unless is_list(help) and Enum.all?(help, &is_binary/1) do
      raise ArgumentError, ":help must be a list of strings, got: #{inspect(help)}"
    end

    unless provenance in [:structural, :heuristic] do
      raise ArgumentError,
            ":provenance must be :structural or :heuristic, got: #{inspect(provenance)}"
    end

    unless is_nil(confidence) or (is_integer(confidence) and confidence in 0..1000) do
      raise ArgumentError,
            ":confidence must be nil or an integer in 0..1000, got: #{inspect(confidence)}"
    end

    %{
      severity: severity,
      title: title,
      detail: detail,
      module: anchor.module,
      mfa: anchor.mfa,
      instr: anchor.instr,
      at_label: at_label,
      at_source: at_source,
      to_instr: to_instr,
      to_block: to_block,
      help: help,
      related: Keyword.get(opts, :related, []),
      provenance: provenance,
      confidence: confidence
    }
  end

  @doc """
  Marks finding attributes as resting on a prior (`Argus.Priors`): one
  severity step down (`:error` to `:warning`, anything else to `:info`),
  `provenance: :heuristic`, `confidence: permille`, and a help line
  saying what the prior said and how sure it was. `at_label` is left as
  it was — it says what the anchor line is, and a prior does not change
  that.

      iex> attrs = Argus.Findings.new(:error, "T", "D.", at_label: "the call")
      iex> h = Argus.Findings.heuristic(attrs, 870, "the sibling is not a process")
      iex> {h.severity, h.provenance, h.confidence, h.at_label}
      {:warning, :heuristic, 870, "the call"}
      iex> h.help
      ["heuristic: the sibling is not a process (p=0.87)"]
  """
  @spec heuristic(attrs(), 0..1000, String.t()) :: attrs()
  def heuristic(%{severity: severity, help: help} = attrs, permille, note)
      when is_integer(permille) and permille in 0..1000 and is_binary(note) do
    p = :erlang.float_to_binary(permille / 1000, decimals: 2)

    %{
      attrs
      | severity: if(severity == :error, do: :warning, else: :info),
        provenance: :heuristic,
        confidence: permille,
        help: help ++ ["heuristic: #{note} (p=#{p})"]
    }
  end

  # ── Names in prose (Argus.Findings.Names) ─────────────────────────

  @doc """
  A callee as a reader writes it (`GenServer.call/2` for the facts'
  `GenServer:call/2`): `Argus.Findings.Names.call_name/1`.
  """
  @spec call_name(String.t()) :: String.t()
  defdelegate call_name(callee), to: Names

  @doc """
  `" in Mod.fun/1"` when a site is not in `func`, else `""`:
  `Argus.Findings.Names.elsewhere/2`.
  """
  @spec elsewhere(String.t(), String.t()) :: String.t()
  defdelegate elsewhere(site, func), to: Names

  @doc "The API an rpc variant column names: `Argus.Findings.Names.rpc_api/1`."
  @spec rpc_api(String.t()) :: String.t()
  defdelegate rpc_api(variant), to: Names

  @doc """
  Labels an anchor as a secondary location. `to:` closes a span from the
  anchor's instruction to that anchor's; `to_block:` names the source
  block for a consumer to close it by when the bytecode gives no end;
  `at_source:` is a source fragment that carries the frame's line the
  last step, as for a finding (`new/4`) — a receive's `loop_rec` has no
  line of its own, so a frame at it says `"receive"`.
  """
  @spec related(String.t(), anchor(), keyword()) :: related()
  def related(label, anchor, opts \\ []) when is_binary(label) do
    to_block = Keyword.get(opts, :to_block)
    at_source = Keyword.get(opts, :at_source)

    unless to_block in [nil | @blocks] do
      raise ArgumentError,
            ":to_block must be one of #{inspect(@blocks)}, got: #{inspect(to_block)}"
    end

    unless is_nil(at_source) or (is_binary(at_source) and at_source != "") do
      raise ArgumentError,
            ":at_source must be a non-empty string, got: #{inspect(at_source)}"
    end

    anchor
    |> Map.put(:label, label)
    |> Map.put(:to_instr, Keyword.get(opts, :to, Anchor.empty()).instr)
    |> Map.put(:to_block, to_block)
    |> Map.put(:at_source, at_source)
  end

  # ── Anchors (Argus.Findings.Anchor) ────────────────────────────────

  @doc "Anchor for an instruction ID string: `Argus.Findings.Anchor.at_instr/1`."
  @spec at_instr(String.t()) :: anchor()
  defdelegate at_instr(id), to: Anchor

  @doc "Anchor for a function ID string: `Argus.Findings.Anchor.at_func/1`."
  @spec at_func(String.t()) :: anchor()
  defdelegate at_func(func_id), to: Anchor

  @doc "Anchor for a known callback on a module string: `Argus.Findings.Anchor.at_mfa/3`."
  @spec at_mfa(String.t(), atom(), arity()) :: anchor()
  defdelegate at_mfa(module_string, func, arity), to: Anchor

  @doc "Anchor for a module string: `Argus.Findings.Anchor.at_module/1`."
  @spec at_module(String.t()) :: anchor()
  defdelegate at_module(module_string), to: Anchor

  @doc """
  Anchor for a site ID of either precision, falling back to a module:
  `Argus.Findings.Anchor.at_site/2`.
  """
  @spec at_site(String.t(), String.t()) :: anchor()
  defdelegate at_site(id, module_string), to: Anchor

  @doc """
  Anchor for a site ID inside a known function, falling back to that
  function: `Argus.Findings.Anchor.at_site_in_func/3`.
  """
  @spec at_site_in_func(String.t(), String.t(), String.t() | nil) :: anchor()
  defdelegate at_site_in_func(site, func_id, module_string \\ nil), to: Anchor

  @doc """
  An `inspect/1`-rendered module string as the module atom, or `nil`:
  `Argus.Findings.Anchor.module_atom/1`.
  """
  @spec module_atom(String.t()) :: module() | nil
  defdelegate module_atom(module_string), to: Anchor
end
