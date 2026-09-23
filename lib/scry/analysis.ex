defmodule Scry.Analysis do
  @moduledoc """
  Incremental argus analysis as a roux query graph.

  ## Query DAG

      module_beam(module)                                 [frontend]
           │
      module_extraction(module)     ← Argus.Pipeline.extract, per module
       │              │
      module_semantic_facts   module_line_table
       (line_info dropped —    (anchor resolution,
        THE cutoff seam)        consumed late by LSP)
           │
      module_relation_facts({module, relation})   ← per-module projection
           │
      relation_facts(relation)      ← one relation across the project
           │
      stage0_facts(:all)
       (shared call graph —
        THE second cutoff seam)
           │
      analysis_facts_dir(analysis)  ← content-addressed, projected to the
           │                          relations THIS analysis reads
      souffle_solve(analysis)
           │
      findings(analysis)

  Planchette's LSP-only surface (`Planchette.SupTree`'s supervision tree,
  `Planchette.Focus`'s flowistry slices) hangs off `module_extraction`
  and `relation_facts` by query name from its own modules; nothing here
  depends on it.

  There is no whole-program fact node. Everything downstream of extraction
  is projected — per module, then per relation, then per analysis — so an
  edit propagates only along the relations it actually moved.

  The line-shift immunity story: a whitespace/comment edit changes the
  beam (Line/Dbgi chunks) → `module_extraction` recomputes and differs
  (its `line_info` rows changed) → `module_semantic_facts` recomputes,
  produces an EQUAL value → roux backdates it → every projection below it
  validates green without executing. Zero Souffle runs for a comment edit.

  The body-edit story: an edit that changes what a function COMPUTES but
  not what it CALLS moves `instruction` and friends, so the analyses that
  anchor at instruction sites re-solve — but `supervisor`, `sync_call` and
  the rest of the structural relations backdate at
  `module_relation_facts`, so `relation_facts` never executes for them and
  the supervision analyses stop before Souffle.

  Rule fidelity: every analysis stays in Souffle — the `.dl` files are
  the single source of truth, and incremental findings must equal batch
  `Argus.Findings.run/2` exactly (the honesty principle). Fact rows are
  sorted per relation so equal extractions produce equal values (roux
  compares with `==`); Souffle has set semantics, so ordering cannot
  change results.

  Purity deviation: `analysis_facts_dir`, `stage0_facts` and
  `souffle_solve` touch the filesystem and shell out — content-addressed
  and idempotent, the same pragmatic loophole as the frontend's code
  loading.

  ## Shared-layer contract

  This module is consumed by BOTH planchette (LSP, in-memory compile
  frontend) and scry's Mix compiler (disk-beam frontend). Roux dispatches
  queries by NAME and memo keys are `{query_name, key}`, so **query
  names, key shapes, and value shapes are the ABI** — rename nothing
  without revisiting every consumer and its persisted manifests. The
  frontend contract this module demands, by name: the queries
  `:module_beam`, `:module_map`, and `:file_of`, and the input
  `:env_fingerprint` (inputs are the frontend's to declare — this module
  defines queries only). The `:rules_digest` input (per analysis, and
  `:stage0`) is optional: a frontend that never sets it reads it as
  `nil` and relies on its `:env_fingerprint` to move when rules do.
  """

  use Roux.Query

  alias Argus.Facts
  alias Roux.Runtime
  alias Scry.Symbols

  # The vsn attribute value is a module checksum no Datalog rule
  # consumes; dropping it keeps any line-sensitivity it might have out
  # of the semantic cutoff.
  @vsn_attribute "vsn"

  # Bumped whenever the on-disk fact encoding changes. Directories are
  # addressed by content, so without this a stale directory written by an
  # older encoder is indistinguishable from a fresh one and gets reused —
  # which is how a malformed empty-relation file survived the fix for it.
  @facts_format_version 2

  # The call graph stage 0 derives, which an analysis's projection takes
  # from `stage0_facts` instead of from extraction.
  @stage0_outputs [:call_edge, :call_site, :call_tag, :unconditional_call_edge]

  defquery :module_extraction, key: module, returns: {:ok, map()} | {:error, term()} do
    # The rows are a function of argus's fact schema as much as of the
    # beam, and the schema version rides the fingerprint — so a warm
    # manifest cannot serve rows an older encoder wrote for an unchanged
    # beam. Without this edge the only reader of the fingerprint was
    # `analysis_input_relations`, and a column reorder would have
    # misaligned every memoized projection silently.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    case Runtime.query(db, :module_beam, module) do
      {:ok, beam} ->
        case take_prewarmed(module, beam) do
          {:ok, result} -> result
          :none -> extract(module, beam, Symbols.for_db(db))
        end

      :external ->
        {:error, {:external, module}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defquery :module_semantic_facts, key: module, returns: {:ok, map()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} ->
        semantic =
          facts
          |> Map.delete(:line_info)
          |> Map.replace_lazy(:module_attribute, fn rows ->
            Enum.reject(rows, fn
              [_mod, @vsn_attribute | _] -> true
              _ -> false
            end)
          end)

        {:ok, semantic}

      {:error, _} = error ->
        error
    end
  end

  defquery :module_line_table, key: module, returns: {:ok, map()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} ->
        symbols = Symbols.for_db(db)

        rows =
          for {id, line} <- Map.get(facts, :line_info, []),
              do: {Argus.Symbols.resolve(symbols, id), line}

        by_instr = Map.new(rows)

        by_func =
          rows
          |> Enum.group_by(
            fn {id, _line} -> id |> String.split("#", parts: 2) |> hd() end,
            fn {_id, line} -> line end
          )
          |> Map.new(fn {func, lines} -> {func, Enum.min(lines)} end)

        {:ok, %{by_instr: by_instr, by_func: by_func}}

      {:error, _} = error ->
        error
    end
  end

  # Every relation's program-wide rows, from one pass over the modules.
  #
  # This used to be one query per (module, relation) — 47,000 memo reads on
  # a 600-module project, each reading the module's whole fact map to take
  # one relation out of it — so a cold run spent most of its time here.
  # One pass reads each module once. Incrementality is unchanged: an edit
  # re-runs this pass (a map merge, well under a second), and every
  # `relation_facts` below it that comes out equal backdates, so the
  # projections and solves downstream still validate without executing.
  defquery :program_relation_facts, key: :all, returns: Facts.interned() do
    modules =
      db
      |> Runtime.query(:module_map, :all)
      |> Map.keys()
      |> Enum.sort()

    # Chunks are collected newest-first and concatenated at the end, so a
    # relation's rows keep module order without quadratic appends.
    modules
    |> Enum.reduce(%{}, fn module, chunks ->
      case Runtime.query(db, :module_semantic_facts, module) do
        {:ok, facts} ->
          Enum.reduce(facts, chunks, fn
            {_relation, []}, chunks -> chunks
            {relation, rows}, chunks -> Map.update(chunks, relation, [rows], &[rows | &1])
          end)

        {:error, _} ->
          chunks
      end
    end)
    |> Map.new(fn {relation, chunks} -> {relation, chunks |> Enum.reverse() |> Enum.concat()} end)
  end

  # One relation's interned rows: the grain the projections read, so a
  # relation the edit did not touch backdates here and stops propagation.
  # A prior relation is the runner's `:prior_rows` input for it, not a
  # module's facts: no extraction produces one. A consumer that demands
  # the graph without setting it (planchette, encore's adapter) gets the
  # empty relation — the meaning of priors off — and the read is still a
  # recorded dependency, so a later `Input.set` invalidates.
  defquery :relation_rows, key: relation, returns: [tuple()] do
    if relation in prior_relations() do
      prior_rows(db, relation)
    else
      db
      |> Runtime.query(:program_relation_facts, :all)
      |> Map.get(relation, [])
    end
  end

  @doc "The layer-3 relation names, as `Argus.Schema` declares them."
  @spec prior_relations() :: [atom()]
  def prior_relations, do: Enum.map(Argus.Schema.layer_3(), & &1.name)

  # The frontend's digest of the Datalog `key` runs — nil for a frontend
  # that does not set it (planchette), recorded as a dependency either
  # way, so a later `Input.set` invalidates.
  defp rules_digest(db, key) do
    Runtime.input(db, :rules_digest, key)
  rescue
    Roux.Input.NotSetError -> nil
  end

  # `Runtime.input/3` records the dependency before it reads, so an
  # unset key is a recorded edge that a later `Input.set` invalidates;
  # the read itself raises, and that is the empty relation.
  defp prior_rows(db, relation) do
    Runtime.input(db, :prior_rows, relation)
  rescue
    Roux.Input.NotSetError -> []
  end

  # The same rows as strings — what a consumer outside this layer reads
  # (planchette's supervision tree). Scry's own path never demands it.
  defquery :relation_facts, key: relation, returns: [[String.t()]] do
    rows = Runtime.query(db, :relation_rows, relation)
    Facts.materialize(%{relation => rows}, Symbols.for_db(db))[relation]
  end

  # Content digest of one relation's rows as they will be written — over
  # the strings, never the ids, because the scratch directories it names
  # are shared between VMs whose tables mint ids in their own order. Fact
  # directories are named from these, so naming one costs a few hashes
  # instead of re-serializing every projected row per analysis, and the
  # digest is recomputed only when the relation's rows change.
  #
  # The rows are stringified once: the text they digest is the text a
  # fact directory needs, so it is written to the shared relation store
  # here, and materializing a directory only links it.
  defquery :relation_digest, key: relation, returns: String.t() do
    rows = Runtime.query(db, :relation_rows, relation)
    stored_digest(relation, rows, Symbols.for_db(db))
  end

  # The same for one of stage 0's outputs: digested and stored once per
  # derivation, however many analyses read it.
  defquery :stage0_digest, key: relation, returns: String.t() | nil do
    case Runtime.query(db, :stage0_facts, :all) do
      {:ok, facts} -> stored_digest(relation, Map.fetch!(facts, relation), Symbols.for_db(db))
      {:error, _} -> nil
    end
  end

  # The relations a given analysis reads, straight from argus (which
  # resolves them from Souffle's transformed RAM — the form that actually
  # executes). A failure to resolve them is a value, never an empty list:
  # an analysis that silently read nothing would solve to no findings.
  defquery :analysis_input_relations,
    key: analysis,
    returns: {:ok, [atom()]} | {:error, term()} do
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _rules = rules_digest(db, analysis)

    case Argus.Analysis.input_relations(analysis) do
      {:ok, relations} -> {:ok, to_relation_atoms(relations)}
      {:error, reason} -> {:error, {:input_relations, reason}}
    end
  end

  # Stage 0: the shared call graph, derived once instead of inside every
  # solve. This is the cutoff seam that makes the whole scheme work — its
  # OUTPUT is far more stable than its input. Editing a function body
  # renumbers `instruction` and churns the control-flow relations, but
  # leaves call_edge byte-identical, so roux backdates this and every
  # analysis downstream validates green.
  #
  # A failed derivation is a value: every analysis that reads the call
  # graph degrades with it, and the driver keeps it out of the manifest.
  defquery :stage0_facts,
    key: :all,
    returns:
      {:ok,
       %{
         call_edge: [tuple()],
         call_site: [tuple()],
         call_tag: [tuple()],
         unconditional_call_edge: [tuple()]
       }}
      | {:error, term()} do
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _rules = rules_digest(db, :stage0)
    symbols = Symbols.for_db(db)

    with {:ok, relations} <- stage0_input_relations(),
         entries =
           for(
             relation <- relations,
             do:
               {relation, Runtime.query(db, :relation_digest, relation),
                Runtime.query(db, :relation_rows, relation)}
           ),
         dir = materialize_facts(entries, "stage0", symbols),
         :ok <- Argus.Analysis.derive_stage0(dir) do
      # Souffle wrote strings; interned like everything else this layer
      # holds.
      {:ok,
       Facts.intern(
         Map.new(@stage0_outputs, &{&1, read_facts_file(Path.join(dir, "#{&1}.facts"))}),
         symbols
       )}
    end
  end

  # A fact directory holding exactly what one analysis reads. Content
  # addressed, so an unchanged projection reuses the directory on disk and
  # — the point — an unchanged projection means roux never re-executes the
  # solve below it. An error when what it reads could not be resolved.
  defquery :analysis_facts_dir,
    key: analysis,
    returns: %{dir: String.t(), key: String.t()} | {:error, term()} do
    with {:ok, entries} <- analysis_facts_entries(db, analysis) do
      dir = materialize_facts(entries, "analysis_#{analysis}", Symbols.for_db(db))
      %{dir: dir, key: Path.basename(dir)}
    end
  end

  # `{:ok, [{relation, digest, rows}]}` for everything the analysis reads.
  defp analysis_facts_entries(db, analysis) do
    with {:ok, relations} <- Runtime.query(db, :analysis_input_relations, analysis),
         {:ok, stage0} <- stage0_if_read(db, relations) do
      entries =
        for relation <- relations do
          if relation in @stage0_outputs do
            # Stage 0's outputs, not extracted relations.
            {relation, Runtime.query(db, :stage0_digest, relation), Map.fetch!(stage0, relation)}
          else
            {relation, Runtime.query(db, :relation_digest, relation),
             Runtime.query(db, :relation_rows, relation)}
          end
        end

      {:ok, entries}
    end
  end

  # Stage 0 only for an analysis that reads the call graph: one that does
  # not must neither wait for it nor degrade with it.
  defp stage0_if_read(db, relations) do
    if Enum.any?(relations, &(&1 in @stage0_outputs)),
      do: Runtime.query(db, :stage0_facts, :all),
      else: {:ok, %{}}
  end

  defquery :souffle_solve, key: analysis, returns: {:ok, map()} | {:error, term()} do
    # The solve is a function of the rules as much as of the facts, and a
    # rule edit need not change which relations the analysis reads — so
    # this reads the digest itself rather than through the projection.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _rules = rules_digest(db, analysis)

    case Runtime.query(db, :analysis_facts_dir, analysis) do
      %{dir: dir} ->
        solve(db, analysis, dir)

      {:error, reason} ->
        {:error, {:souffle, analysis, reason}}
    end
  end

  defp solve(db, analysis, dir) do
    # The scratch window is shared across processes (an LSP session and a
    # compiler run prune the same root), so a concurrent prune can remove
    # a directory the memo above still names. Rebuild before solving:
    # content addressing guarantees the same path, and `untracked` keeps
    # the rebuild's demands out of this query's dependency edges — the
    # graph must look identical whether or not the race happened.
    unless File.dir?(dir) do
      Runtime.untracked(fn ->
        {:ok, entries} = analysis_facts_entries(db, analysis)
        materialize_facts(entries, "analysis_#{analysis}", Symbols.for_db(db))
      end)
    end

    # The directory holds exactly the relations this analysis reads, with
    # the call graph already supplied from `stage0_facts` when it is among
    # them. Argus must not try to derive stage 0 itself: the layer-1 facts
    # it would need are deliberately absent from a projected directory.
    case Argus.Analysis.run_rules(dir, analysis, stage0: :provided) do
      {:ok, results} ->
        outputs =
          results
          |> Argus.Analysis.filter_to_outputs(analysis)
          |> Map.new(fn {relation, rows} -> {relation, Enum.sort(rows)} end)

        {:ok, outputs}

      {:error, reason} ->
        # Degradation stays a visible value (Souffle missing/timeout),
        # never a crash — the argus contract. The driver keeps it out of
        # the manifest, so the next run solves again.
        {:error, {:souffle, analysis, reason}}
    end
  end

  # Line-free by construction (anchors are module/mfa/instr IDs, not
  # lines) → findings backdate independently of line edits, and the
  # per-analysis grain means an analysis whose output rows are unchanged
  # stops propagation even when others changed.
  defquery :findings, key: analysis, returns: {:ok, [map()]} | {:error, term()} do
    # Argus builds the findings: its code moving must rebuild them even
    # when the solved rows backdate.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    case Runtime.query(db, :souffle_solve, analysis) do
      {:ok, outputs} ->
        module = analysis_module!(analysis)
        {:ok, build_findings(module, outputs)}

      {:error, _} = error ->
        error
    end
  end

  # Findings with anchors resolved to file + line — the LATE positional
  # step: findings themselves are line-free, so this is the only query
  # that re-runs when a line-shifting edit touches an anchored module.
  # Grouped by file, ready for LSP publication.
  defquery :analysis_diagnostics,
    key: analysis,
    returns: {:ok, %{optional(String.t()) => [map()]}} | {:error, term()} do
    # Scry's own resolution: its code moving must re-resolve even when
    # the findings backdate.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    case Runtime.query(db, :findings, analysis) do
      {:ok, findings} ->
        resolved =
          for finding <- findings,
              entry = resolve_finding(db, finding),
              entry != nil,
              do: entry

        {:ok, Enum.group_by(resolved, & &1.file)}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_finding(db, finding) do
    module = anchor_module(finding)

    with true <- module != nil,
         path when path != :external <- Runtime.query(db, :file_of, module) do
      line = source_line(db, module, path, finding)
      guard = guard_word(path, line, finding)

      %{
        file: path,
        line: line,
        end_line: end_line(db, module, path, finding),
        severity: finding.severity,
        code: Atom.to_string(finding.analysis),
        title: fill_guard(finding.title, guard),
        detail: fill_guard(finding.detail, guard),
        # Map.get, not dot access: findings memoized before the shape
        # gained these fields (a warm manifest) must still resolve.
        at_label: fill_guard(Map.get(finding, :at_label), guard),
        help: Enum.map(Map.get(finding, :help, []), &fill_guard(&1, guard)),
        related: resolve_related(db, Map.get(finding, :related, [])),
        provenance: Map.get(finding, :provenance, :structural),
        confidence: Map.get(finding, :confidence)
      }
    else
      _ -> nil
    end
  end

  defp resolve_related(db, related) do
    for entry <- related,
        module = anchor_module(entry),
        module != nil,
        path = Runtime.query(db, :file_of, module),
        path != :external do
      # The frame's own source fragment takes its line the last step, as
      # a finding's does: a receive's loop_rec has no line, so the
      # bytecode alone puts the frame on the function head.
      line = source_line(db, module, path, entry)

      %{
        label: fill_guard(Map.get(entry, :label, ""), guard_word(path, line, entry)),
        file: path,
        line: line,
        end_line: end_line(db, module, path, entry)
      }
    end
  end

  # The word for `{guard}` in a finding's prose: the keyword the source
  # shows at the anchor when the finding sits in a guard, else the
  # neutral one. Read only when the prose asks.
  defp guard_word(path, line, anchored) do
    if Map.get(anchored, :to_block) == :guard,
      do: Scry.SourceAnchor.guard_keyword(path, line) || "handler",
      else: "handler"
  end

  defp fill_guard(nil, _word), do: nil
  defp fill_guard(text, word), do: String.replace(text, "{guard}", word)

  # The bytecode's end of the span when it placed one; else the end of
  # the source block the finding says its anchor sits in, if it names
  # one. Same untracked read, same tracked signal, as source_line/4.
  defp end_line(db, module, path, anchored) do
    span_end_line(db, module, anchored) ||
      Scry.SourceAnchor.block_end(
        path,
        source_line(db, module, path, anchored),
        Map.get(anchored, :to_block)
      )
  end

  # A finding or frame that closes a span names a second instruction;
  # its line is where the bracket ends. Nil when there is no span, or
  # the end resolves no later than the start.
  defp span_end_line(db, module, anchored) do
    case Map.get(anchored, :to_instr) do
      nil ->
        nil

      to ->
        start = anchor_line(db, module, anchored)

        case Runtime.query(db, :module_line_table, module) do
          {:ok, table} ->
            case instr_line(table, to) do
              line when is_integer(line) and line > start -> line
              _ -> nil
            end

          {:error, _} ->
            nil
        end
    end
  end

  # NOTE: InstrId fields are the fact-encoded STRINGS ("Depot.Archive"),
  # not atoms — anchors resolved through file_of must come from the
  # finding's module/mfa fields (atoms, present whenever the instr
  # parsed).
  defp anchor_module(%{module: module}) when is_atom(module) and module != nil, do: module
  defp anchor_module(%{mfa: {module, _f, _a}}) when is_atom(module), do: module
  defp anchor_module(_), do: nil

  # Best-effort line resolution through the module's line table:
  # instruction ID → exact line; MFA → the function's first line;
  # module-only → line 1 (the defmodule line is not recoverable from
  # bytecode — an honest, predictable anchor).
  defp anchor_line(db, module, finding) do
    case Runtime.query(db, :module_line_table, module) do
      {:ok, table} ->
        instr_line(table, Map.get(finding, :instr)) ||
          mfa_line(table, Map.get(finding, :mfa)) || 1

      {:error, _} ->
        1
    end
  end

  # The bytecode anchor, then the source's last step for a finding that
  # names a fragment. The file read is untracked on purpose: the tracked
  # signal is the module's line table, and an edit that moves a
  # declaration moves the functions after it too. The one shape that
  # slips by — an edit inside a schema block with no function below it
  # in the file — leaves a stale line until the next real change.
  defp source_line(db, module, path, finding) do
    line = anchor_line(db, module, finding)
    Scry.SourceAnchor.refine(path, line, Map.get(finding, :at_source))
  end

  defp instr_line(_table, nil), do: nil

  # InstrId fields are already the fact-encoded strings — reassemble the
  # id exactly as line_info keys it.
  defp instr_line(table, %Argus.InstrId{module: m, func: f, arity: a, idx: idx}) do
    id = "#{m}:#{f}/#{a}##{idx}"
    Map.get(table.by_instr, id) || Map.get(table.by_func, "#{m}:#{f}/#{a}")
  end

  defp mfa_line(_table, nil), do: nil

  defp mfa_line(table, {m, f, a}) do
    Map.get(table.by_func, "#{inspect(m)}:#{f}/#{a}")
  end

  # -- helpers --

  @doc """
  The union of every built-in analysis's extractors (coverage excluded,
  mirroring `Argus.Findings.run/2`) — one extraction serves all solves.
  """
  @spec all_extractors() :: [module()]
  def all_extractors do
    analysis_extractors =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.reject(&(&1.name() == :coverage))
      |> Enum.flat_map(& &1.extractors())

    # Resource extractors power planchette's supervision-tree overlay — ETS
    # tables and ports attributed to their owning process — over this same
    # extraction. ETS also rides the `ets` analysis, but list both
    # explicitly so the overlay never depends on which analyses happen to
    # be built in.
    (analysis_extractors ++ [Argus.Extractors.ETS, Argus.Extractors.ApiCalls])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The always-on analyses (keynote-narrative, low-noise): argus's
  `:default` set. The rest run on demand.
  """
  @spec default_analyses() :: [atom()]
  def default_analyses do
    {:ok, analyses} = Argus.Analysis.set(:default)
    analyses
  end

  @doc """
  Extracts `modules` in parallel ahead of the query graph.

  Queries execute one at a time on the demanding process, so a cold run
  extracted every module serially. This runs the extraction for the given
  `module => beam_path` map across the schedulers and parks each result
  for `module_extraction` to pick up — the query still executes, records
  its dependencies and memoizes as before, it just finds its answer
  waiting. A result is keyed by the canonical beam's digest, so a beam
  that changed between the pre-pass and the query is extracted again.
  """
  @spec prewarm_extractions(%{optional(module()) => String.t()}, Roux.Database.t()) :: :ok
  def prewarm_extractions(paths, db) when is_map(paths) do
    symbols = Symbols.for_db(db)

    paths
    |> Task.async_stream(
      fn {module, path} ->
        case File.read(path) do
          {:ok, raw} ->
            beam = Scry.Beam.canonical(raw)
            {module, :erlang.md5(beam), extract(module, beam, symbols)}

          {:error, _} ->
            nil
        end
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, {module, digest, result}} ->
        Process.put({__MODULE__, :prewarmed, module}, {digest, result})

      _ ->
        :ok
    end)
  end

  defp take_prewarmed(module, beam) do
    key = {__MODULE__, :prewarmed, module}

    case Process.get(key) do
      {digest, result} ->
        Process.delete(key)
        if digest == :erlang.md5(beam), do: {:ok, result}, else: :none

      nil ->
        :none
    end
  end

  # Rows are memoized interned: the ids' meaning lives in the database's
  # intern table, persisted with the memo that holds them. They are
  # sorted as strings first — an id's value depends on the order the
  # table met its symbol in, which parallel extraction does not fix, so
  # sorting by id would make a module's row order (and everything
  # downstream that keeps it, such as the supervision tree's resource
  # lists) vary from run to run for the same beam.
  defp extract(module, beam, symbols) do
    case Argus.Pipeline.extract([beam], extractors: all_extractors(), trace_imprecision: true) do
      {:ok, facts} -> {:ok, facts |> canonicalize() |> Facts.intern(symbols)}
      {:error, reason} -> {:error, {:extraction, module, reason}}
    end
  end

  defp canonicalize(facts) do
    Map.new(facts, fn {relation, rows} -> {relation, Enum.sort(rows)} end)
  end

  defp analysis_module!(analysis) do
    Enum.find(Argus.Analysis.builtin_analysis_modules(), &(&1.name() == analysis)) ||
      raise ArgumentError, "unknown argus analysis: #{inspect(analysis)}"
  end

  # Argus builds the findings from the solved rows (deduplicated by each
  # relation's identity rule, evidence relations attached as related
  # frames), so incremental findings equal batch findings field for field.
  defp build_findings(module, outputs), do: Argus.Findings.build(module, outputs)

  defp scratch_root do
    Path.join(System.tmp_dir!(), "scry_souffle")
  end

  # How many fact directories to keep. Each edit that moves a relation
  # mints a new content-addressed directory, and nothing else ever removes
  # them — an editing session used to grow the scratch root without bound
  # (measured at 506MB / 31 directories after a single afternoon). Keeping
  # a window preserves the point of content addressing (re-visiting a
  # previous state is still a hit) while bounding the cost.
  @scratch_keep 24

  # Writes `{relation, digest, rows}` entries to a directory named for
  # their digests, and returns it. Idempotent: identical facts map to the
  # same directory, which is what makes revisiting a prior edit state free.
  defp materialize_facts(entries, prefix, symbols) do
    key =
      {@facts_format_version,
       Enum.map(entries, fn {relation, digest, _rows} -> {relation, digest} end)}
      |> digest()

    dir = Path.join(scratch_root(), "#{prefix}_#{key}")
    unless File.dir?(dir), do: write_facts_dir!(entries, dir, symbols)
    dir
  end

  # One relation's rows as the tab-separated lines Souffle reads.
  defp rows_iodata(relation, rows, symbols) do
    %{^relation => strings} = Facts.materialize(%{relation => rows}, symbols)
    Enum.map(strings, fn row -> [Enum.intersperse(row, "\t"), "\n"] end)
  end

  # The digest of `rows` as Souffle will read them, with the text written
  # to the relation store under it on the way.
  defp stored_digest(relation, rows, symbols) do
    text = rows_iodata(relation, rows, symbols)
    digest = text |> :erlang.md5() |> Base.encode16(case: :lower)
    _path = store_relation(relation, digest, fn -> text end)
    digest
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  defp write_facts_dir!(entries, dir, symbols) do
    # Build under a unique temporary name and rename into place, so a
    # concurrent reader never observes a half-written directory and
    # concludes the facts are simply missing (Souffle reads an absent
    # relation as empty for pruned inputs, which would be a silent wrong
    # answer rather than a loud failure).
    staging = "#{dir}.#{System.unique_integer([:positive])}"
    File.mkdir_p!(staging)
    write_projected_facts!(entries, staging, symbols)

    case File.rename(staging, dir) do
      :ok -> :ok
      # Lost the race to an identical directory: content-addressed, so
      # the winner's contents are ours. Drop the duplicate.
      {:error, _} -> File.rm_rf!(staging)
    end

    maybe_prune_scratch()
    :ok
  end

  # Writes exactly the projected relations and nothing else.
  #
  # Deliberately not `Argus.Pipeline.write_facts/2`, which pre-creates an
  # empty file for every schema relation so Souffle never fails on a
  # missing input. That is the right default for a full extraction and the
  # wrong one here: it would make an under-projection FAIL SILENTLY, with
  # Souffle reading a relation we forgot to supply as empty and returning
  # fewer findings. Writing only what we projected makes the same mistake
  # abort with "cannot open fact file", which is the failure mode a static
  # analyzer should have.
  #
  # Each relation's file is written once per digest under `relations/` and
  # hard-linked into every directory that projects it, so twenty-six
  # analyses sharing `def_use` cost one write of it, not twenty-six.
  defp write_projected_facts!(entries, dir, symbols) do
    Enum.each(entries, fn {relation, digest, rows} ->
      source = relation_file!(relation, digest, rows, symbols)
      target = Path.join(dir, "#{relation}.facts")

      case File.ln(source, target) do
        :ok -> :ok
        {:error, _} -> File.cp!(source, target)
      end
    end)
  end

  # The digest already stored the file; this regenerates it only when the
  # store's pruning removed it since.
  defp relation_file!(relation, digest, rows, symbols) do
    store_relation(relation, digest, fn -> rows_iodata(relation, rows, symbols) end)
  end

  defp store_relation(relation, digest, text) do
    root = Path.join(scratch_root(), "relations")
    path = Path.join(root, "#{relation}_#{digest}.facts")

    unless File.exists?(path) do
      File.mkdir_p!(root)
      staging = "#{path}.#{System.unique_integer([:positive])}"
      File.write!(staging, text.())

      case File.rename(staging, path) do
        :ok -> :ok
        {:error, _} -> File.rm(staging)
      end
    end

    path
  end

  @relations_keep 512

  # Pruning lists and stats the whole store, so it runs at most once a
  # minute per VM rather than on every directory written — a run writes a
  # dozen, concurrently.
  @prune_interval_ms 60_000

  defp maybe_prune_scratch do
    clock = prune_clock()
    now = System.monotonic_time(:millisecond)
    last = :atomics.get(clock, 1)

    if last == 0 or now - last >= @prune_interval_ms do
      # Whoever swaps the timestamp prunes; a concurrent writer skips.
      if :atomics.compare_exchange(clock, 1, last, now) == :ok, do: prune_scratch()
    end

    :ok
  end

  defp prune_clock do
    case :persistent_term.get({__MODULE__, :prune_clock}, nil) do
      nil ->
        clock = :atomics.new(1, signed: true)
        :persistent_term.put({__MODULE__, :prune_clock}, clock)
        clock

      clock ->
        clock
    end
  end

  @doc false
  # Bounds the scratch root: the newest fact directories, and the newest
  # files of the shared relation store. Public for tests.
  @spec prune_scratch() :: :ok
  def prune_scratch do
    root = scratch_root()
    relations = Path.join(root, "relations")
    prune_relation_files(relations)

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        # The relation store is not a fact directory: pruning it as one
        # (when it was not among the newest) threw away every relation
        # file, so each run stringified them all again.
        |> Enum.filter(&(&1 != relations and File.dir?(&1)))
        |> Enum.map(fn dir ->
          mtime =
            case File.stat(dir, time: :posix) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> 0
            end

          {mtime, dir}
        end)
        |> Enum.sort(:desc)
        |> Enum.drop(@scratch_keep)
        |> Enum.each(fn {_mtime, dir} -> File.rm_rf(dir) end)

      {:error, _} ->
        :ok
    end

    :ok
  end

  # A directory's hard links survive the shared file's removal, so this
  # only bounds the store; nothing that was linked breaks.
  defp prune_relation_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.map(fn path ->
          mtime =
            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> 0
            end

          {mtime, path}
        end)
        |> Enum.sort(:desc)
        |> Enum.drop(@relations_keep)
        |> Enum.each(fn {_mtime, path} -> File.rm(path) end)

      {:error, _} ->
        :ok
    end
  end

  # Relation names arrive from argus as strings. Only relations the schema
  # knows can appear in an extraction, so an unknown name is dropped
  # rather than minting an atom from external input.
  defp to_relation_atoms(names) do
    known = MapSet.new(Argus.Schema.names())

    for name <- names,
        atom = safe_existing_atom(name),
        atom != nil,
        atom in @stage0_outputs or MapSet.member?(known, atom),
        do: atom
  end

  defp safe_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # The layer-1 relations stage0.dl reads, asked of Souffle rather than
  # hardcoded, so adding a call-graph rule upstream cannot silently leave
  # the projection feeding stage 0 an incomplete fact set.
  defp stage0_input_relations do
    case Argus.Souffle.input_relations(Argus.Analysis.stage0_rules_path()) do
      {:ok, relations} -> {:ok, to_relation_atoms(relations)}
      {:error, reason} -> {:error, {:stage0, {:input_relations, reason}}}
    end
  end

  # Souffle fact files are tab separated, one tuple per line.
  defp read_facts_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
