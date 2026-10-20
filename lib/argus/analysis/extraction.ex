defmodule Argus.Analysis.Extraction do
  @moduledoc """
  The stages derived over a facts directory, for a caller that solves
  the rules over one (`Argus.Analysis.run_rules/3`, over a directory
  `Argus.Analysis.extract_facts/3` wrote or one written by hand); the
  query graph derives them itself (`Argus.Graph.Solve`):

  - **Stage 0** (`priv/dl/stage0.dl`) derives the shared call graph
    (`call_edge`, `call_site`, `unconditional_call_edge`, `call_tag`,
    `call_tag_arity`, `fun_handed_to`, `fun_built`) once, so no analysis
    re-derives it and the volatile instruction-level relations stay out of
    every analysis's input set.
  - **Points-to** (`priv/dl/points_to.dl`), when an analysis reads it,
    derives which objects a variable can hold (`points_to_relations/0`)
    once: the fixpoint is most of a solve over a large program, and it
    is the same for every analysis that asks. A program whose full
    fixpoint outgrows the stage's budget runs it selective instead
    (`priv/dl/points_to_selective.dl`, see `derive_points_to/2`).

  `Argus.Analysis` delegates `derive_stage0/2`, `derive_points_to/2`,
  their rules paths and relation lists here.
  """

  alias Argus.Analysis
  alias Argus.Stages

  # The relations stage 0 writes; a directory holding every one is staged.
  @stage0_relations ~w(call_edge call_site unconditional_call_edge call_tag call_tag_arity
                         fun_handed_to fun_built)

  # The relations the points-to stage writes (points_to.dl's outputs):
  # what the analyses read, and which stage wrote them.
  @points_to_relations ~w(server_process instance supervised_process private_process process
                          named_pid process_call process_signal call_site_target self_call
                          var_process var_table approximated_table approximated_process
                          kept_in_dictionary
                          task_handled task_escapes points_to_mode)

  @doc """
  Derives the stage-0 relations into an existing facts directory.

  Stage 0 is the shared call graph (`call_edge`): every client analysis
  needs it, and before stratification each one re-derived it inside its
  own solve from the layer-1 bytecode relations. Deriving it once here
  removes that redundancy, and — more importantly for incremental
  consumers — keeps `instruction`, `remote_call` and friends out of the
  input set of analyses that only reason about supervision structure.

  `Argus.Analysis.run_rules/3` derives it when a directory lacks it
  (`ensure_stage0/2`). Its output is markedly more stable than its
  inputs: it moves only when the *call* structure changes, not when a
  function body does.

  Writes the `stage0_relations/0` files into `facts_dir`, none when it
  fails. The solver writes them into a directory of its own, and each
  is renamed into place whole, so a reader of `facts_dir` never sees one
  being written. Idempotent, and safe beside another derivation into
  the same directory: re-running replaces each file with the same
  content for the same inputs.

  `:rules_path` selects an editable copy of the stage program for a debug
  reproduction. It defaults to the shipped program and changes no global state.
  """
  @spec derive_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_stage0(facts_dir, opts \\ []) do
    # stage0.dl names its outputs `.facts`, so the directory they land in
    # is directly reusable as a fact directory.
    result =
      with {:ok, _results, aside} <-
             solve_aside(facts_dir, Keyword.get(opts, :rules_path, stage0_rules_path()), opts) do
        try do
          publish(aside, facts_dir, @stage0_relations)
        after
          File.rm_rf(aside)
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:stage0, reason}}
    end
  end

  # A stage solved over `facts_dir` into a directory of its own inside
  # it, never into `facts_dir` itself: `{:ok, results, aside}`, the
  # outputs in `aside` for `publish/3`, or the solve's error (`aside`
  # gone). Inside, so a rename moves each output into place: the same
  # volume, whoever made the directory.
  defp solve_aside(facts_dir, rules_path, opts) do
    aside = Path.join(facts_dir, ".stage-#{:os.getpid()}-#{System.unique_integer([:positive])}")

    case File.mkdir(aside) do
      :ok ->
        case Argus.FlowLog.run(facts_dir, rules_path, Keyword.put(opts, :output_dir, aside)) do
          {:ok, results} ->
            {:ok, results, aside}

          {:error, _} = error ->
            File.rm_rf(aside)
            error
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, aside, reason}}
    end
  end

  # Each `.facts` file a stage wrote into `aside`, renamed into
  # `facts_dir` over what is there: `required` names the relations it
  # must have written. A reader of `facts_dir` sees each file whole, the
  # old one or the new, never one being written.
  #
  # Never solved in place: a directory can have several readers and
  # writers at once. A caller may name fact directories by their content,
  # so every solve over the same facts derives the same stage into the
  # same one. An engine opens an output truncated and writes it where it
  # stands, so a reader there would see a file cut short; and a stage's
  # reports, read back and removed from there, would be removed from
  # under another derivation that has written them and not yet read
  # them (`{:missing_output, "points_to_overflow"}`).
  defp publish(aside, facts_dir, required) do
    with {:ok, names} <- File.ls(aside) do
      written = names |> Enum.filter(&String.ends_with?(&1, ".facts")) |> Enum.sort()

      case Enum.reject(required, &("#{&1}.facts" in written)) do
        [] -> rename_each(written, aside, facts_dir)
        [missing | _] -> {:error, {:missing_output, missing}}
      end
    end
  end

  defp rename_each(names, from, to) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case File.rename(Path.join(from, name), Path.join(to, name)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:publish_failed, name, reason}}}
      end
    end)
  end

  @doc "The path to the stage-0 rules file."
  @spec stage0_rules_path() :: Path.t()
  def stage0_rules_path, do: Argus.Dl.path("stage0.dl")

  @doc "The relations stage 0 writes."
  @spec stage0_relations() :: [String.t()]
  def stage0_relations, do: @stage0_relations

  @doc """
  Derives the points-to stage into an existing facts directory that
  stage 0 has been derived into.

  Points-to (`clientlib/processes.dl`) is a whole-program
  fixpoint, and every analysis that asks which process a pid can be
  used to derive it inside its own solve: over a large program, most of
  the solve, and the same rows each time. This derives them once, and
  the analyses read `points_to_relations/0` as facts
  (`clientlib/staged_processes.dl`).

  Like stage 0, an incremental consumer calls it directly and memoizes
  the result: its outputs move only when a process or a resolved target
  does, not on every edit that renumbers the instructions it reads.

  The stage is field-sensitive within a budget: `points_to_rules_path/0`
  holds its fixpoint to 500,000 rows of what a variable may point to and
  of what a term's field may hold, where the largest of twenty programs
  it was measured on holds 45,000. A program whose helpers merge most of
  its terms into one value grows past that with the square of those
  terms (Ash: 13 million rows after thirteen minutes) and runs selective
  instead (`points_to_selective_rules_path/0`): the hub objects (held by
  more than one variable in a hundred) are resolved by a
  field-insensitive pass, a superset of their full rows, and every other
  object field-sensitively. The budget is decided over the finished fixpoint,
  so which stage runs is a function of the facts: the same facts run
  the same stage on any machine, under any load, afresh or from a store.
  `points_to_mode.facts` says which one wrote the relations, and a
  warning names the hub objects a selective stage resolved
  field-insensitively. The engine stops a fixpoint as a relation grows
  past the budget (`.limitsize`), so a program that outgrows it pays for
  the full stage only until it does, before the selective one runs,
  within the solve's timeout.

  A selective stage that outgrows the budget too runs field-insensitive
  (`points_to_field_insensitive_rules_path/0`): every object resolved by
  the field-insensitive pass, whose rows grow with the program's
  variables and objects rather than with its terms. Where the terms merge
  into each other, each holding every other's fields, the selective
  stage outgrows the budget whichever objects it resolves
  field-sensitively; the field-insensitive one answers for every object
  what the selective one answers for a hub, and the run's notice says so
  (`Argus.Report.Notice`).

  A stage that outgrows the budget even field-insensitive, or does not finish
  within `:timeout`, fails with a warning, `{:error,
  {:points_to, reason}}`, and the analyses that read it degrade
  (`Argus.Findings.run/2`): time can fail the stage, never change what
  it answers.

  Writes the `points_to_relations/0` files into `facts_dir`, each renamed
  into place whole (as stage 0's, `derive_stage0/2`), and none when it
  fails: a failure leaves the directory as it found it. What the stage
  reports (its overflow, its hub objects) is read back, never left
  among the facts. Idempotent, and safe beside another derivation into
  the same directory.

  `:rules_path`, `:selective_rules_path` and
  `:field_insensitive_rules_path` select copied stage programs for a
  debug reproduction. All default to the shipped programs. The same
  budget policy and publication contract apply to those copies.
  """
  @spec derive_points_to(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_points_to(facts_dir, opts \\ []) do
    # Each solve over `facts_dir` into a directory of its own; the last
    # one's outputs are the stage's, any before it (a full stage that
    # outgrew its budget: what it had reached, none of it an answer)
    # are discarded with it.
    solve = fn rules_path, {dir, asides} ->
      with {:ok, results, aside} <- solve_aside(dir, rules_path, opts),
           do: {:ok, results, {dir, [aside | asides]}}
    end

    {result, asides} =
      case Stages.points_to(
             solve,
             {facts_dir, []},
             Keyword.get(opts, :rules_path, points_to_rules_path()),
             Keyword.get(opts, :selective_rules_path, points_to_selective_rules_path()),
             Keyword.get(
               opts,
               :field_insensitive_rules_path,
               points_to_field_insensitive_rules_path()
             )
           ) do
        {:ok, {_dir, [aside | _] = asides}, _mode} ->
          {publish(aside, facts_dir, @points_to_relations), asides}

        {:error, reason, {_dir, asides}} ->
          {{:error, reason}, asides}
      end

    Enum.each(asides, &File.rm_rf/1)

    case result do
      :ok -> :ok
      {:error, reason} -> Stages.failed(reason)
    end
  end

  @doc "The path to the points-to stage's rules file."
  @spec points_to_rules_path() :: Path.t()
  def points_to_rules_path, do: Argus.Dl.path("points_to.dl")

  @doc """
  The path to the selective points-to stage's rules file: what
  `derive_points_to/2` runs when the full stage outgrows its budget. A
  consumer that keys the stage on its programs keys it on this one too.
  """
  @spec points_to_selective_rules_path() :: Path.t()
  def points_to_selective_rules_path, do: Argus.Dl.path("points_to_selective.dl")

  @doc """
  The path to the field-insensitive points-to stage's rules file: what
  `derive_points_to/2` runs when even the selective stage outgrows its
  budget. A consumer that keys the stage on its programs keys it on this
  one too.
  """
  @spec points_to_field_insensitive_rules_path() :: Path.t()
  def points_to_field_insensitive_rules_path, do: Argus.Dl.path("points_to_field_insensitive.dl")

  @doc "The relations the points-to stage writes."
  @spec points_to_relations() :: [String.t()]
  def points_to_relations, do: @points_to_relations

  @doc """
  Whether an analysis reads what the points-to stage writes, as FlowLog
  resolves its inputs (`Argus.Analysis.input_relations/2`). An analysis
  whose inputs cannot be resolved is taken to read it: deriving the
  stage then reports the real trouble.
  """
  @spec reads_points_to?(Analysis.analysis(), keyword()) :: boolean()
  def reads_points_to?(analysis, opts \\ []) do
    case Analysis.input_relations(analysis, opts) do
      {:ok, relations} -> Enum.any?(relations, &(&1 in @points_to_relations))
      {:error, _} -> true
    end
  end

  @doc """
  Derives the points-to stage into `facts_dir` when one of `analyses`
  reads it and it is not already there.

  `stage0: :provided` in `opts` opts out, as it does for stage 0: a
  caller that projects a directory per analysis supplies the staged
  relations the analysis reads itself.
  """
  @spec ensure_points_to(Path.t(), [Analysis.analysis()], keyword()) :: :ok | {:error, term()}
  def ensure_points_to(facts_dir, analyses, opts) do
    cond do
      Keyword.get(opts, :stage0, :auto) == :provided ->
        :ok

      Enum.all?(@points_to_relations, &File.exists?(Path.join(facts_dir, "#{&1}.facts"))) ->
        :ok

      not Enum.any?(analyses, &reads_points_to?/1) ->
        :ok

      true ->
        derive_points_to(facts_dir, opts)
    end
  end

  @doc """
  Derives stage 0 into `facts_dir` unless it is already there.

  Analyses read the staged call graph, so it has to be there. Deriving it
  only when absent keeps this a no-op on the hot path: `extract_facts/3`
  already staged it, and incremental callers supply a directory that
  carries their own memoized copy. Hand-built fact directories — tests,
  ad-hoc probes — get it derived on demand rather than having to know
  about staging at all.

  `stage0: :provided` in `opts` opts out entirely, of this stage and of
  the points-to one (`ensure_points_to/3`). A caller that projects a
  fact directory down to exactly the relations one analysis reads knows
  whether call_edge is among them; for an analysis that does not read it
  the file is legitimately absent, and auto-deriving would fail on the
  layer-1 facts such a directory deliberately omits.
  """
  @spec ensure_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_stage0(facts_dir, opts) do
    cond do
      Keyword.get(opts, :stage0, :auto) == :provided ->
        :ok

      Enum.all?(@stage0_relations, &File.exists?(Path.join(facts_dir, "#{&1}.facts"))) ->
        :ok

      true ->
        derive_stage0(facts_dir, opts)
    end
  end
end
