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

  ## Atom creation

  Anchor parsing converts module and function name strings back to atoms
  with `String.to_atom/1`. Those names come from BEAM files the caller
  asked Argus to disassemble, so the atoms already exist in this node's
  atom table — parsing does not grow it. Do not feed findings from
  untrusted `.beam` files into a long-lived node; run Argus in a sandbox
  process instead (this is how lowdown consumes uploads).
  """

  alias Argus.Analysis
  alias Argus.InstrId
  alias Argus.Souffle

  defstruct findings: [], ran: [], degraded: []

  @typedoc "Finding severity, in decreasing order of urgency."
  @type severity :: :error | :warning | :info

  @typedoc "Code location attached to a finding, most precise field wins."
  @type anchor :: %{
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil
        }

  @typedoc "A labelled secondary location (sibling, supervisor, callee, ...)."
  @type related :: %{
          label: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil
        }

  @typedoc "What an analysis module's `finding/2` callback returns."
  @type attrs :: %{
          severity: severity(),
          title: String.t(),
          detail: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil,
          related: [related()]
        }

  @typedoc "A finding: `attrs` plus the analysis that produced it."
  @type finding :: %{
          analysis: atom(),
          severity: severity(),
          title: String.t(),
          detail: String.t(),
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil,
          related: [related()]
        }

  @typedoc "Per-analysis run record for analyses that completed."
  @type ran_entry :: %{
          analysis: atom(),
          duration_ms: non_neg_integer(),
          finding_count: non_neg_integer()
        }

  @typedoc "Per-analysis degradation note for analyses that did not complete."
  @type degradation :: %{analysis: atom(), reason: term(), detail: String.t()}

  @type t :: %__MODULE__{
          findings: [finding()],
          ran: [ran_entry()],
          degraded: [degradation()]
        }

  @severity_rank %{error: 0, warning: 1, info: 2}
  @severities Map.keys(@severity_rank)

  # ── Running ────────────────────────────────────────────────────────

  @doc """
  Runs analyses against the given modules and returns structured findings.

  `modules` is a list of module atoms or paths to `.beam` files, exactly
  as `Argus.analyze/3` accepts.

  ## Options

  - `:analyses` — `:all` (default) or a list of built-in analysis names.
    `:all` means every built-in analysis except `:coverage`, which measures
    the extractor pipeline rather than the analyzed code.
  - All `Argus.Analysis.run/3` options (`:concurrency`, `:extractors`,
    `:souffle_bin`, `:souffle_timeout`, ...) pass through.

  Returns `{:ok, %Argus.Findings{}}` or `{:error, reason}` — see the
  moduledoc for the degradation contract.
  """
  @spec run(modules :: [atom() | String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def run(modules, opts \\ []) when is_list(modules) and is_list(opts) do
    {selection, opts} = Keyword.pop(opts, :analyses, :all)

    with {:ok, analysis_mods} <- resolve_selection(selection),
         :ok <- ensure_souffle(opts) do
      evaluate(modules, analysis_mods, opts)
    end
  end

  defp evaluate(_modules, [], _opts), do: {:ok, %__MODULE__{}}

  defp evaluate(modules, analysis_mods, opts) do
    names = Enum.map(analysis_mods, & &1.name())

    with {:ok, facts_dir} <- Analysis.extract_facts(modules, names, opts) do
      outcomes =
        analysis_mods
        |> Task.async_stream(&run_one(&1, facts_dir, opts),
          max_concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
          ordered: true,
          # Souffle.run bounds each evaluation with :souffle_timeout, so the
          # task itself never needs a second, racing deadline.
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      {:ok, collect(outcomes)}
    end
  end

  defp run_one(mod, facts_dir, opts) do
    name = mod.name()
    {elapsed_us, result} = :timer.tc(fn -> Analysis.run_rules(facts_dir, name, opts) end)

    case result do
      {:ok, results} ->
        try do
          findings = build_findings(mod, Analysis.filter_to_outputs(results, name))

          ran = %{
            analysis: name,
            duration_ms: div(elapsed_us, 1000),
            finding_count: length(findings)
          }

          {:ran, ran, findings}
        rescue
          exception ->
            {:degraded,
             %{
               analysis: name,
               reason: {:finding_builder_crashed, exception},
               detail:
                 "The #{name} analysis ran, but converting its results to findings " <>
                   "crashed: #{Exception.message(exception)}. This is a bug in Argus."
             }}
        end

      {:error, reason} ->
        {:degraded, %{analysis: name, reason: reason, detail: degradation_detail(name, reason)}}
    end
  end

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

  defp build_findings(mod, results) do
    relations = Map.new(mod.output_relations(), &{Atom.to_string(&1.name), &1})
    has_builder? = function_exported?(mod, :finding, 2)

    for {relation_string, rows} <- Enum.sort(results),
        relation = Map.fetch!(relations, relation_string),
        row <- rows do
      attrs =
        if has_builder? do
          mod.finding(relation.name, row)
        else
          generic_finding(relation, row)
        end

      Map.put(attrs, :analysis, mod.name())
    end
  end

  # Fallback for behaviour implementors that don't define finding/2:
  # severity :info, prose from the relation's declared doc, anchor from
  # the first row value that parses as an instruction or function ID.
  defp generic_finding(relation, row) do
    fields =
      relation.fields
      |> Enum.zip(row)
      |> Enum.map_join(", ", fn {{name, _kind, _doc}, value} -> "#{name}=#{value}" end)

    anchor =
      Enum.find_value(row, empty_anchor(), fn value ->
        case at_instr(value) do
          %{instr: nil} ->
            case at_func(value) do
              %{mfa: nil} -> nil
              anchor -> anchor
            end

          anchor ->
            anchor
        end
      end)

    new(:info, humanize(relation.name), "#{relation.doc} (#{fields})", at: anchor)
  end

  defp humanize(relation_name) do
    relation_name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

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

  defp resolve_selection(:all) do
    {:ok, Enum.reject(Analysis.builtin_analysis_modules(), &(&1.name() == :coverage))}
  end

  defp resolve_selection(names) when is_list(names) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Analysis.fetch_module(name) do
        {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
        :error -> {:halt, {:error, {:unknown_analysis, name}}}
      end
    end)
    |> case do
      {:ok, mods} -> {:ok, Enum.reverse(mods)}
      error -> error
    end
  end

  defp resolve_selection(other), do: {:error, {:invalid_analyses, other}}

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
  - `:related` — list of `related/2` entries (default: `[]`).
  """
  @spec new(severity(), String.t(), String.t(), keyword()) :: attrs()
  def new(severity, title, detail, opts \\ [])
      when severity in @severities and is_binary(title) and is_binary(detail) do
    anchor = Keyword.get(opts, :at, empty_anchor())

    %{
      severity: severity,
      title: title,
      detail: detail,
      module: anchor.module,
      mfa: anchor.mfa,
      instr: anchor.instr,
      related: Keyword.get(opts, :related, [])
    }
  end

  @doc "Labels an anchor as a secondary location."
  @spec related(String.t(), anchor()) :: related()
  def related(label, anchor) when is_binary(label) do
    Map.put(anchor, :label, label)
  end

  @doc """
  Anchor for an instruction ID string (`"Mod:func/arity#idx"`).

  Unparseable input (a `"dynamic"` placeholder, free-form text) yields an
  empty anchor rather than an error — anchors are best-effort by design.
  """
  @spec at_instr(String.t()) :: anchor()
  def at_instr(id) when is_binary(id) do
    case InstrId.parse(id) do
      {:ok, instr} ->
        anchor = at_parts(instr.module, instr.func, instr.arity)
        %{anchor | instr: instr}

      :error ->
        empty_anchor()
    end
  end

  @doc "Anchor for a function ID string (`\"Mod:func/arity\"`)."
  @spec at_func(String.t()) :: anchor()
  def at_func(func_id) when is_binary(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{module: module, func: func, arity: arity}} -> at_parts(module, func, arity)
      :error -> empty_anchor()
    end
  end

  @doc """
  Anchor for a known callback on a module string.

  Several relations report a module known to implement a specific callback
  (`init/1`, `handle_cast/2`, ...) without carrying a function ID — this
  reconstructs the precise anchor.
  """
  @spec at_mfa(String.t(), atom(), arity()) :: anchor()
  def at_mfa(module_string, func, arity)
      when is_binary(module_string) and is_atom(func) and is_integer(arity) do
    case module_atom(module_string) do
      nil -> empty_anchor()
      module -> %{module: module, mfa: {module, func, arity}, instr: nil}
    end
  end

  @doc "Anchor for a module string (`\"MyApp.Cache\"` or `\":lists\"`)."
  @spec at_module(String.t()) :: anchor()
  def at_module(module_string) when is_binary(module_string) do
    %{module: module_atom(module_string), mfa: nil, instr: nil}
  end

  @doc """
  Converts an `inspect/1`-rendered module string back to the module atom.

  Returns `nil` for the `"dynamic"` placeholder and anything else that
  isn't a module rendering.
  """
  @spec module_atom(String.t()) :: module() | nil
  def module_atom("dynamic"), do: nil
  def module_atom(""), do: nil
  def module_atom(":"), do: nil

  def module_atom(":" <> erlang_name) do
    String.to_atom(strip_quotes(erlang_name))
  end

  def module_atom(alias_string) do
    if String.match?(alias_string, ~r/^[A-Z]/) do
      Module.concat([alias_string])
    else
      nil
    end
  end

  defp at_parts(module_string, func, arity) do
    case module_atom(module_string) do
      nil -> empty_anchor()
      module -> %{module: module, mfa: {module, String.to_atom(func), arity}, instr: nil}
    end
  end

  defp empty_anchor, do: %{module: nil, mfa: nil, instr: nil}

  # Quoted Erlang atoms render as :"foo bar" — strip the quotes.
  defp strip_quotes(name) do
    case name do
      <<?", inner::binary>> -> String.trim_trailing(inner, "\"")
      _ -> name
    end
  end
end
