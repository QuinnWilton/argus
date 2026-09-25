defmodule Scry.Analysis do
  @moduledoc """
  Incremental argus analysis as a roux query graph.

  ## Query DAG

      module_beam(module)          extraction_code(:all)  [inputs]
           │                        │
      module_extraction(module)     ← every argus producer's rows, per
       │              │               module (Argus.Pipeline.extract_shards),
       │              │               and schema_read(entry) for each entry
       │              │               of argus's schema it read
      module_semantic_facts   module_line_table
       (digest of the facts    (anchor resolution,
        minus line_info —       consumed late)
        THE cutoff seam)
           │
      program_relation_facts(:all)  ← every module's facts merged once,
           │                          read through the digests above
      relation_rows(relation) ─ relation_digest(relation)
           │                    (the rows' text, stored once)
      stage0_facts(:all) ─ stage0_digest(relation)
       (shared call graph —
        THE second cutoff seam)
           │
      points_to_facts(:all) ─ points_to_digest(relation)
       (process points-to, read by the
        analyses that ask about processes —
        a third seam: most edits move no
        process and no resolved target)
           │
      analysis_facts_dir(analysis)  ← content-addressed, projected to the
           │                          relations THIS analysis reads
      souffle_solve(analysis)       ← and rules_digest(analysis)
           │
      findings(analysis) → analysis_diagnostics(analysis)

  Planchette's LSP-only surface (`Planchette.SupTree`'s supervision tree,
  `Planchette.Focus`'s flowistry slices) hangs off `module_extraction`
  and `relation_facts` (the rows as strings) by query name from its own
  modules; nothing here depends on it.

  The whole program meets in one node, `program_relation_facts`, and is
  projected from there — per relation, then per analysis — so an edit
  propagates past it only along the relations it actually moved.

  The argus-edit story: a module's extraction is keyed by the code
  argus's fact producers run, as one digest (`:extraction_code`,
  `Scry.Fingerprint.extraction_code/0`). An edit to an extractor or to
  what they all run re-extracts every module, and where a module's rows
  come out equal its semantic digest backdates, so nothing above it
  runs. An edit outside that code — the findings' prose, the analyses
  modules, the Souffle wrapper — extracts nothing: it rebuilds the
  findings (`:argus_code`), and solves nothing.

  The schema-edit story: argus's schema (`Argus.Schema`) is data, and
  every accessor of it records the entry it returned
  (`Argus.Cache.Reads`). Every query here that reads it — extraction,
  whose producers decode a few relations by their columns and whose
  rows are interned by them; the relations' text; the projections'
  relation lists — depends on each entry it read (`schema_read(entry)`,
  its digest now), and on nothing else of the schema. So a relation
  added, a version bump or another relation's prose reruns nothing but
  the digests of the entries read so far; a relation's columns changed
  re-extract the modules whose rows it holds, and re-solve only the
  programs that load it (`:rules_digest` keys a program by the
  declarations it loads).

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

  Purity deviation: `analysis_facts_dir`, `stage0_facts`,
  `points_to_facts` and `souffle_solve` touch the filesystem and shell
  out — content-addressed and idempotent, the same pragmatic loophole as
  the frontend's code loading.

  ## Shared-layer contract

  This module is consumed by BOTH planchette (LSP, in-memory compile
  frontend) and scry's Mix compiler (disk-beam frontend). Roux dispatches
  queries by NAME and memo keys are `{query_name, key}`, so **query
  names, key shapes, and value shapes are the ABI** — rename nothing
  without revisiting every consumer and its persisted manifests. The
  frontend contract this module demands, by name: the queries
  `:module_beam`, `:module_map`, and `:file_of`, and the input
  `:env_fingerprint` (inputs are the frontend's to declare — this module
  defines queries only). The `:rules_digest` input (per analysis,
  `:stage0` and `:points_to`) is optional: a frontend that never sets it
  reads it as `nil` and relies on its `:env_fingerprint` to move when
  rules do. So are `:extraction_code` (`:all`, the code argus's fact
  producers run) and `:argus_code` (`:all`, every argus beam): a
  frontend without them relies on its `:env_fingerprint` to move when
  argus does. So is the `:ignored_beam` input (per module): it names the
  modules the frontend watches without analyzing, whose specs a caller's
  extraction reads off the code path.
  """

  use Roux.Query

  alias Argus.Cache.Reads
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
  # from `stage0_facts` instead of from extraction. Named by argus, as the
  # points-to outputs are: a relation stage 0 gains is read from its
  # output, never looked for in extraction's rows.
  @stage0_outputs Enum.map(Argus.Analysis.stage0_relations(), &String.to_atom/1)

  # What the points-to stage derives (which process a pid can be), which
  # a projection takes from `points_to_facts`. Named by argus, which
  # stages them: the list moves with its rules.
  @points_to_outputs Enum.map(Argus.Analysis.points_to_relations(), &String.to_atom/1)

  defquery :module_extraction, key: module, returns: {:ok, map()} | {:error, term()} do
    # The rows are a function of the runtime as much as of the beam.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)

    # And of the code argus's producers run, which moves without moving
    # argus's version: an extractor edit re-extracts. And of the entries
    # of argus's schema they read (`depend_on_schema/2`, below): a column
    # reorder re-extracts the modules whose rows it holds, where a warm
    # manifest would otherwise serve rows misaligned with every
    # projection.
    _code = optional_input(db, :extraction_code, :all)

    # A retry of a failed extraction moves this.
    _attempt = optional_input(db, :extraction_attempt, module)

    case Runtime.query(db, :module_beam, module) do
      {:ok, beam} ->
        {result, installed, schema} =
          case take_prewarmed(module, beam) do
            {:ok, extracted} -> extracted
            :none -> extract(module, beam, Symbols.for_db(db))
          end

        :ok = track_reads(db, module, installed)
        :ok = depend_on_schema(db, schema)
        result

      :external ->
        {:error, {:external, module}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An input's value, read (and so depended on) only when the frontend
  # set it: an edge to an input with no value validates as stale, and
  # every validation of the reader would run it again.
  defp optional_input(db, input, key) do
    if Roux.Input.exists?(db, input, key), do: Runtime.input(db, input, key)
  end

  # One entry of argus's fact schema, by the name its accessor recorded
  # it under (`Argus.Cache.Reads`: `"columns call_arg"`, `"fetch
  # supervisor"`): the digest of what the entry is now
  # (`Argus.Cache.Reads.digest/1`). A query that read the schema depends
  # on each entry it read through this (`reading_schema/2`), not on the
  # schema's code, so a schema edit reruns exactly the queries that read
  # what it changed: a relation added, a version bump or another
  # relation's prose reruns none.
  #
  # The entries are data compiled into argus's schema modules, so they
  # move only with argus's code: this reads `:argus_code`, and on an
  # argus edit every entry read so far is digested again (a few hundred
  # small terms), backdating wherever it came out equal. A query, not an
  # input the driver sets, because what an extraction reads is known only
  # after it ran, often inside the graph, where no input can be set.
  defquery :schema_read, key: read, returns: String.t() do
    _argus = optional_input(db, :argus_code, :all)
    schema_digest(read)
  end

  @doc false
  # What `schema_read` holds for `read` now: the driver looks ahead with
  # it (`Scry.Runner`) for the modules whose extraction read an entry
  # that moved.
  @spec schema_digest(String.t()) :: String.t()
  def schema_digest(read), do: Reads.digest(read)

  # Runs `fun` (no query of this graph: what one read is its own) and
  # makes the running query depend on each schema entry it read.
  defp reading_schema(db, fun) do
    {result, reads} = Reads.track(fun)
    :ok = depend_on_schema(db, reads)
    result
  end

  # An edge to each of `reads` (`schema_read`), for a frontend that keys
  # argus's code (`:argus_code`); one that does not (planchette) relies
  # on its fingerprint to move with argus, as it does for the rest of
  # argus's code, and records none.
  defp depend_on_schema(_db, []), do: :ok

  defp depend_on_schema(db, reads) do
    if Roux.Input.exists?(db, :argus_code, :all),
      do: Enum.each(reads, &Runtime.query(db, :schema_read, &1))

    :ok
  end

  # What the specs extractor read off the code path for this module
  # (`Argus.Pipeline.extract_shards/3`'s `installed`: each module whose
  # specs or types it looked up, found or not). The environment digest
  # in the fingerprint covers every application there but argus's own
  # and the ones the frontend watches; a read of one of those records an
  # edge that moves with it:
  #
  # - a module of the program: an edge to its `file_of`. The rules
  #   ignore installed rows for a callee while it is analyzed (its own
  #   rows win) and read them once it is gone, so what matters is that it
  #   appears, leaves or moves; `file_of` moves exactly then and
  #   backdates otherwise.
  # - a module the frontend watches without analyzing (`:ignored_beam`,
  #   scry's `ignore: [modules: ...]`): an edge to that input, which
  #   moves whenever its beam — and so its specs — does.
  # - a module of argus's own application (a program that calls argus):
  #   an edge to `:argus_code`, which moves with every argus beam.
  #
  # Which reads are which is decided without an edge. A read that found
  # no module stays unrecorded: a module that appears later in a
  # dependency moves the environment, and one that appears in the
  # program is analyzed, so its own rows win.
  defp track_reads(_db, _module, []), do: :ok

  defp track_reads(db, module, reads) do
    program = db |> program_modules() |> MapSet.new()
    argus = argus_modules()

    argus_read? =
      Enum.reduce(reads, false, fn read, argus_read? ->
        cond do
          read == module ->
            argus_read?

          MapSet.member?(program, read) ->
            _ = Runtime.query(db, :file_of, read)
            argus_read?

          Roux.Input.exists?(db, :ignored_beam, read) ->
            _ = Runtime.input(db, :ignored_beam, read)
            argus_read?

          true ->
            argus_read? or MapSet.member?(argus, read)
        end
      end)

    # One edge however many of argus's modules were read.
    if argus_read?, do: _ = optional_input(db, :argus_code, :all)
    :ok
  end

  # Argus's own modules, once per VM.
  defp argus_modules do
    key = {__MODULE__, :argus_modules}

    case :persistent_term.get(key, nil) do
      nil ->
        _ = Application.load(:panoptes)
        modules = MapSet.new(Application.spec(:panoptes, :modules) || [])
        :persistent_term.put(key, modules)
        modules

      modules ->
        modules
    end
  end

  # The modules the frontend analyzes: the keys of its `:module_map`, as
  # everywhere else in this layer, demanded without an edge. Scry's
  # frontend builds the map from its module set, planchette's from the
  # files it compiles; reading scry's `:module_set` input here left
  # planchette, which has none, tracking no callee at all.
  defp program_modules(db) do
    Runtime.untracked(fn -> db |> Runtime.query(:module_map, :all) |> Map.keys() end)
  end

  # The digest of what a module contributes to the program's relations:
  # its facts without line_info (and the vsn attribute, a checksum no rule
  # reads). A line-only edit re-extracts the module, this comes out equal,
  # and roux backdates it — THE early-cutoff seam. It holds the digest
  # rather than the facts because the facts are module_extraction's
  # already: a second copy was a sixth of the manifest.
  defquery :module_semantic_facts, key: module, returns: {:ok, binary()} | {:error, term()} do
    case Runtime.query(db, :module_extraction, module) do
      {:ok, facts} ->
        {:ok,
         facts
         |> semantic(Symbols.for_db(db))
         |> :erlang.term_to_binary([:deterministic])
         |> :erlang.md5()}

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

    symbols = Symbols.for_db(db)

    # Chunks are collected newest-first and concatenated at the end, so a
    # relation's rows keep module order without quadratic appends.
    modules
    |> Enum.reduce(%{}, fn module, chunks ->
      case Runtime.query(db, :module_semantic_facts, module) do
        {:ok, _digest} ->
          # The dependency is on the digest: an edit that moves only
          # lines leaves it equal and never reaches here. The facts are
          # read without an edge, and are current — the digest was just
          # validated against them.
          {:ok, facts} =
            Runtime.untracked(fn -> Runtime.query(db, :module_extraction, module) end)

          facts
          |> semantic(symbols)
          |> Enum.reduce(chunks, fn
            {_relation, []}, chunks -> chunks
            {relation, rows}, chunks -> Map.update(chunks, relation, [rows], &[rows | &1])
          end)

        {:error, _} ->
          chunks
      end
    end)
    |> Map.new(fn {relation, chunks} -> {relation, chunks |> Enum.reverse() |> Enum.concat()} end)
  end

  # What extraction could not do, program-wide: each module that could not
  # be extracted at all, and each step argus recorded as failing on a
  # module (`extraction_error` rows — an extractor that raised, a module
  # that outlived the per-module timeout). The analyses ran over
  # everything else, so these are findings that may be missing, not
  # analyses that failed.
  defquery :extraction_errors,
    key: :all,
    returns: [%{module: module() | nil, name: String.t(), step: String.t(), reason: String.t()}] do
    modules = db |> Runtime.query(:module_map, :all) |> Map.keys()
    by_name = Map.new(modules, &{inspect(&1), &1})

    whole =
      for module <- modules,
          {:error, reason} <- [Runtime.query(db, :module_semantic_facts, module)] do
        %{module: module, name: inspect(module), step: "module", reason: one_line(reason)}
      end

    steps =
      for [name, step, reason] <- Runtime.query(db, :relation_facts, :extraction_error) do
        %{module: Map.get(by_name, name), name: name, step: step, reason: reason}
      end

    Enum.sort(whole ++ steps)
  end

  defp one_line(reason), do: reason |> inspect(limit: 20) |> String.replace(~r/\s+/, " ")

  # One relation's interned rows: the grain the projections read, so a
  # relation the edit did not touch backdates here and stops propagation.
  # A prior relation is the runner's `:prior_rows` input for it, not a
  # module's facts: no extraction produces one. A consumer that demands
  # the graph without setting it (planchette, encore's adapter) gets the
  # empty relation — the meaning of priors off — and the read is still a
  # recorded dependency, so a later `Input.set` invalidates.
  defquery :relation_rows, key: relation, returns: [tuple()] do
    if reading_schema(db, fn -> prior?(relation) end) do
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

  # Whether `relation` is a prior, reading that relation's entry alone:
  # the whole of layer 3 moves with any prior's prose.
  defp prior?(relation), do: match?({:ok, %{layer: 3}}, Argus.Schema.fetch(relation))

  # The frontend's digest of the Datalog `key` runs, or nil for a frontend
  # that does not set it (planchette). Only a set digest is read, so only
  # a set digest is a dependency: roux validates an edge to an input with
  # no value as stale, and every validation of a solve would re-run it.
  # Scry's runner sets every digest before it demands anything.
  defp rules_digest(db, key) do
    if Roux.Input.exists?(db, :rules_digest, key), do: Runtime.input(db, :rules_digest, key)
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
    symbols = Symbols.for_db(db)
    reading_schema(db, fn -> Facts.materialize(%{relation => rows}, symbols)[relation] end)
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
  #
  # The text is argus's encoding of the rows (`Argus.Tsv`, base code), so
  # it is keyed by the code argus's producers run, as argus keys the fact
  # shards it writes: an edit to the encoding writes the relations again.
  defquery :relation_digest, key: relation, returns: String.t() do
    _encoding = optional_input(db, :extraction_code, :all)
    rows = Runtime.query(db, :relation_rows, relation)
    symbols = Symbols.for_db(db)
    reading_schema(db, fn -> stored_digest(relation, rows, symbols) end)
  end

  # The same for one of stage 0's outputs: digested and stored once per
  # derivation, however many analyses read it.
  defquery :stage0_digest, key: relation, returns: String.t() | nil do
    _encoding = optional_input(db, :extraction_code, :all)

    case Runtime.query(db, :stage0_facts, :all) do
      {:ok, facts} -> stored_output_digest(db, relation, Map.fetch!(facts, relation))
      {:error, _} -> nil
    end
  end

  # The same for one of the points-to stage's outputs.
  defquery :points_to_digest, key: relation, returns: String.t() | nil do
    _encoding = optional_input(db, :extraction_code, :all)

    case Runtime.query(db, :points_to_facts, :all) do
      {:ok, facts} -> stored_output_digest(db, relation, Map.fetch!(facts, relation))
      {:error, _} -> nil
    end
  end

  # A stage output's digest, stored: its text is written by its columns.
  defp stored_output_digest(db, relation, rows) do
    symbols = Symbols.for_db(db)
    reading_schema(db, fn -> stored_digest(relation, rows, symbols) end)
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
      {:ok, relations} -> {:ok, reading_schema(db, fn -> to_relation_atoms(relations) end)}
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

    with {:ok, relations} <- reading_schema(db, &stage0_input_relations/0),
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
      {:ok, reading_schema(db, fn -> intern_outputs(@stage0_outputs, dir, symbols) end)}
    end
  end

  # A stage's outputs from the directory Souffle wrote them to, interned
  # by their columns.
  defp intern_outputs(outputs, dir, symbols) do
    Facts.intern(
      Map.new(outputs, &{&1, read_facts_file(Path.join(dir, "#{&1}.facts"))}),
      symbols
    )
  end

  # The points-to stage: which process a pid can be, derived once for
  # every analysis that asks instead of inside each of their solves. It
  # reads PidFlow's per-function summaries, which move with most body
  # edits, but its outputs (the processes, the resolved targets) rarely
  # do: roux backdates it, and the analyses reading it validate green.
  #
  # A failed derivation is a value, as stage 0's is: the analyses that
  # read it degrade with it, the others never demand it.
  defquery :points_to_facts,
    key: :all,
    returns: {:ok, %{atom() => [tuple()]}} | {:error, term()} do
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _rules = rules_digest(db, :points_to)
    symbols = Symbols.for_db(db)

    with {:ok, relations} <- reading_schema(db, &points_to_input_relations/0),
         {:ok, stage0} <- stage0_if_read(db, relations),
         entries = Enum.map(relations, &relation_entry(db, &1, stage0, %{})),
         dir = materialize_facts(entries, "points_to", symbols),
         :ok <- Argus.Analysis.derive_points_to(dir) do
      {:ok, reading_schema(db, fn -> intern_outputs(@points_to_outputs, dir, symbols) end)}
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
         {:ok, stage0} <- stage0_if_read(db, relations),
         {:ok, points_to} <- points_to_if_read(db, relations) do
      {:ok, Enum.map(relations, &relation_entry(db, &1, stage0, points_to))}
    end
  end

  # `{relation, digest, rows}`: a stage's output from that stage, any
  # other relation from extraction.
  defp relation_entry(db, relation, stage0, points_to) do
    cond do
      relation in @stage0_outputs ->
        {relation, Runtime.query(db, :stage0_digest, relation), Map.fetch!(stage0, relation)}

      relation in @points_to_outputs ->
        {relation, Runtime.query(db, :points_to_digest, relation),
         Map.fetch!(points_to, relation)}

      true ->
        {relation, Runtime.query(db, :relation_digest, relation),
         Runtime.query(db, :relation_rows, relation)}
    end
  end

  # Stage 0 only for an analysis that reads the call graph: one that does
  # not must neither wait for it nor degrade with it.
  defp stage0_if_read(db, relations) do
    if Enum.any?(relations, &(&1 in @stage0_outputs)),
      do: Runtime.query(db, :stage0_facts, :all),
      else: {:ok, %{}}
  end

  # The points-to stage likewise, only for an analysis that reads it.
  defp points_to_if_read(db, relations) do
    if Enum.any?(relations, &(&1 in @points_to_outputs)),
      do: Runtime.query(db, :points_to_facts, :all),
      else: {:ok, %{}}
  end

  defquery :souffle_solve, key: analysis, returns: {:ok, map()} | {:error, term()} do
    # The solve is a function of the rules as much as of the facts, and a
    # rule edit need not change which relations the analysis reads — so
    # this reads the digest itself rather than through the projection.
    # How argus runs Souffle and reads its output is keyed as argus keys
    # its own solves: by the program and the solver's version (the rules
    # digest), not by argus's code.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _rules = rules_digest(db, analysis)

    case Runtime.query(db, :analysis_facts_dir, analysis) do
      %{dir: dir} ->
        solve(db, analysis, dir)

      {:error, reason} ->
        {:error, {:souffle, analysis, reason}}
    end
  end

  defp solve(db, analysis, dir, attempts \\ 2) do
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
    # the call graph and the points-to already supplied from
    # `stage0_facts` and `points_to_facts` when they are among them.
    # Argus must not try to derive either stage itself: the facts they
    # would need are deliberately absent from a projected directory.
    case Argus.Analysis.run_rules(dir, analysis, stage0: :provided) do
      {:ok, results} ->
        outputs =
          results
          |> Argus.Analysis.filter_to_outputs(analysis)
          |> Map.new(fn {relation, rows} -> {relation, Enum.sort(rows)} end)

        {:ok, outputs}

      {:error, reason} ->
        # The same race, lost during the solve: another process pruned
        # the directory while Souffle was reading it. Rebuild and solve
        # once more rather than report a failure of the scratch space.
        if attempts > 1 and not intact?(db, analysis, dir) do
          # A half-pruned directory would pass the File.dir? check.
          File.rm_rf(dir)
          solve(db, analysis, dir, attempts - 1)
        else
          # Degradation stays a visible value (Souffle missing/timeout),
          # never a crash — the argus contract. The driver keeps it out
          # of the manifest, so the next run solves again.
          {:error, {:souffle, analysis, reason}}
        end
    end
  end

  # A fact directory still as materialized: every relation the analysis
  # reads has its file there.
  defp intact?(db, analysis, dir) do
    {:ok, entries} = Runtime.untracked(fn -> analysis_facts_entries(db, analysis) end)

    Enum.all?(entries, fn {relation, _digest, _rows} ->
      File.regular?(Path.join(dir, "#{relation}.facts"))
    end)
  end

  # Line-free by construction (anchors are module/mfa/instr IDs, not
  # lines) → findings backdate independently of line edits, and the
  # per-analysis grain means an analysis whose output rows are unchanged
  # stops propagation even when others changed.
  defquery :findings, key: analysis, returns: {:ok, [map()]} | {:error, term()} do
    # Argus builds the findings: its code moving must rebuild them even
    # when the solved rows backdate. Every argus beam, not the
    # extraction's code: the prose and the identity rules live outside
    # it, and a rebuild is cheap.
    _fingerprint = Runtime.input!(db, :env_fingerprint, :all)
    _argus = optional_input(db, :argus_code, :all)

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

  # A module's facts as the analyses read them: without line_info, and
  # without the vsn attribute. Rows are interned, so the attribute's key
  # is compared as the string it stands for.
  defp semantic(facts, symbols) do
    facts
    |> Map.delete(:line_info)
    |> Map.replace_lazy(:module_attribute, fn rows ->
      Enum.reject(rows, fn row ->
        tuple_size(row) > 1 and Argus.Symbols.resolve(symbols, elem(row, 1)) == @vsn_attribute
      end)
    end)
  end

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
  its dependencies (the reads the extraction made among them) and
  memoizes as before, it just finds its answer waiting. A result is
  keyed by the canonical beam's digest, so a beam that changed between
  the pre-pass and the query is extracted again.
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
      {:ok, {module, digest, extracted}} ->
        Process.put({__MODULE__, :prewarmed, module}, {digest, extracted})

      _ ->
        :ok
    end)
  end

  # `{:ok, {result, installed, schema}}` parked for this beam, or `:none`.
  defp take_prewarmed(module, beam) do
    key = {__MODULE__, :prewarmed, module}

    case Process.get(key) do
      {digest, extracted} ->
        Process.delete(key)
        if digest == :erlang.md5(beam), do: {:ok, extracted}, else: :none

      nil ->
        :none
    end
  end

  # A module's facts, `{result, installed, schema}`: its rows from every
  # producer — argus's base and each of `all_extractors/0` — or its
  # error; the modules the specs extractor read off the code path for it
  # (`track_reads/3`); and the schema entries producing and interning
  # its rows read (`depend_on_schema/2`). `Argus.Pipeline.extract_shards/3`
  # hands each producer's rows back apart, and they are joined here: what
  # matters to this graph is the module, whose rows are keyed by all of
  # the producers' code at once (`:extraction_code`) and by every entry
  # any of them read.
  #
  # Rows are memoized interned: the ids' meaning lives in the database's
  # intern table, persisted with the memo that holds them. They are
  # sorted as strings first — an id's value depends on the order the
  # table met its symbol in, which parallel extraction does not fix, so
  # sorting by id would make a module's row order (and everything
  # downstream that keeps it, such as the supervision tree's resource
  # lists) vary from run to run for the same beam.
  defp extract(module, beam, symbols) do
    opts = [trace_imprecision: true]

    # Argus's per-module timeout unless the application sets one (tests
    # use a tiny one to see a module time out).
    opts =
      case Application.get_env(:scry, :extraction_timeout) do
        nil -> opts
        ms -> Keyword.put(opts, :timeout, ms)
      end

    case Argus.Pipeline.extract_shards([beam], [:base | all_extractors()], opts) do
      {:ok, shards, %{installed: installed, reads: reads}} ->
        # Interning reads each relation's columns: the rows depend on
        # those entries as much as on the ones the producers read.
        {facts, interned} =
          Reads.track(fn -> shards |> join_producers() |> Facts.intern(symbols) end)

        schema = [interned | Map.values(reads)] |> Enum.concat() |> Enum.uniq() |> Enum.sort()
        {{:ok, facts}, installed, schema}

      {:error, reason} ->
        {{:error, {:extraction, module, reason}}, [], []}
    end
  end

  # One fact map from each producer's: a relation several producers
  # write holds all of their rows, sorted.
  defp join_producers(shards) do
    shards
    |> Enum.flat_map(fn {_producer, facts} -> Map.to_list(facts) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.concat() |> Enum.sort()} end)
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

  # One relation's rows as the lines Souffle reads, fields escaped as
  # argus writes them (a tab or newline in a name would otherwise move
  # every column after it, and Souffle would refuse the file).
  defp rows_iodata(relation, rows, symbols) do
    %{^relation => strings} = Facts.materialize(%{relation => rows}, symbols)
    Argus.Tsv.encode(strings)
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
      link_relation!(relation, digest, rows, symbols, Path.join(dir, "#{relation}.facts"))
    end)
  end

  # Links a stored relation file into a fact directory (a copy where the
  # filesystem cannot link). Another process pruning the store can remove
  # the file between storing and linking, and an interrupted writer can
  # leave something at its name that is not the file: either way the
  # entry is cleared and stored again, once.
  defp link_relation!(relation, digest, rows, symbols, target, attempts \\ 2) do
    source = relation_file!(relation, digest, rows, symbols)

    with {:error, _} <- File.ln(source, target),
         {:error, reason} <- File.cp(source, target) do
      if attempts > 1 do
        File.rm_rf(source)
        link_relation!(relation, digest, rows, symbols, target, attempts - 1)
      else
        raise File.CopyError, reason: reason, action: "copy", source: source, destination: target
      end
    end

    :ok
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
  # rather than minting an atom from external input. Each is looked up
  # alone (its columns, not the list of every name): the caller depends
  # on the entries it read, and a relation added elsewhere is none.
  defp to_relation_atoms(names) do
    for name <- names,
        atom = safe_existing_atom(name),
        atom != nil,
        atom in @stage0_outputs or atom in @points_to_outputs or
          Argus.Schema.columns(atom) != :error,
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

  # What points_to.dl reads, asked of Souffle for the same reason: stage
  # 0's outputs among them, taken from `stage0_facts`.
  defp points_to_input_relations do
    case Argus.Souffle.input_relations(Argus.Analysis.points_to_rules_path()) do
      {:ok, relations} -> {:ok, to_relation_atoms(relations)}
      {:error, reason} -> {:error, {:points_to, {:input_relations, reason}}}
    end
  end

  # Souffle fact files are tab separated, one tuple per line, fields
  # escaped (`Argus.Tsv`).
  defp read_facts_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> Argus.Tsv.decode()
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
