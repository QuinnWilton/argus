defmodule Argus.Test.Graph do
  @moduledoc """
  Drives `Argus.Graph` directly over a roux database, without Mix: the
  harness for the incremental≡batch parity gate and for tests that need
  to reach into the graph (a failing solver, a moved rule digest).

  The parity set is a subset of argus's own fixtures (`parity!/0`), as
  the test build compiles them.
  """

  alias Roux.{Database, GC, Input}

  # The fixture files the parity set is made of: argus's own, for the
  # relations the whole-program analyses lean on (process points-to,
  # unreceived messages, check-then-act over registries, ETS and Mnesia,
  # the PADL 2010 Erlang race programs) and one per remaining concern, so
  # every analysis in `:all` has rows to agree on.
  @parity_sources ~w(
    call_cycle_fixture.ex check_then_act_fixture.ex consistency_fixture.ex
    dynamic_supervisor_fixture.ex ets_fixture.ex gen_statem_fixture.ex
    pid_flow_fixture.ex secret_fixture.ex shutdown_fixture.ex
    supervision_fixture.ex taint_fixture.ex timeout_chain_fixture.ex
    transaction_fixture.ex unreceived_message_fixture.ex unsafe_task_fixture.ex
    erl/dialyzer_whereis_unregister.erl erl/padl2010_ets_inc.erl
    erl/padl2010_higher_order.erl erl/padl2010_loop.erl erl/padl2010_proc_reg.erl
    erl/padl2010_registered.erl erl/padl2010_snmp_shadow_table.erl
    erl/padl2010_time_stamp.erl
  )

  @doc """
  The parity set: `module => beam_path` for every module argus's own
  fixture files in `@parity_sources` define, as the test build compiled
  them (with debug info, into this application's ebin, on the code path
  of this VM and of every peer). Found once per VM.
  """
  @spec parity!() :: %{optional(module()) => String.t()}
  def parity! do
    key = {__MODULE__, :parity}

    case :persistent_term.get(key, nil) do
      nil ->
        paths = find_parity()
        :persistent_term.put(key, paths)
        paths

      paths ->
        paths
    end
  end

  # Each beam of this application's ebin whose compile info names one of
  # the parity sources: read from the beam, not the loaded module, so no
  # fixture is loaded to be asked.
  defp find_parity do
    suffixes = Enum.map(@parity_sources, &("/test/fixtures/" <> &1))
    ebin = :panoptes |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")

    paths =
      for beam <- Path.wildcard(Path.join(ebin, "*.beam")),
          {:ok, {module, [compile_info: info]}} <-
            [:beam_lib.chunks(String.to_charlist(beam), [:compile_info])],
          source = info |> Keyword.get(:source, []) |> to_string(),
          Enum.any?(suffixes, &String.ends_with?(source, &1)),
          into: %{},
          do: {module, beam}

    if map_size(paths) == 0, do: raise("no parity fixture beams found in #{ebin}")
    paths
  end

  @doc """
  `paths`, for a peer handed them: the parity beams are in this
  application's ebin, which is on every peer's code path already.
  """
  @spec use_parity!(%{optional(module()) => String.t()}) :: %{optional(module()) => String.t()}
  def use_parity!(paths), do: paths

  @doc """
  The suite's blob store, `_build/test/argus/store` (beside the beams,
  so `mix clean` takes it too), or a temporary one under
  `ARGUS_NO_CACHE`.
  """
  @spec store() :: Roux.Blob.t()
  def store do
    if Argus.Cache.enabled?(),
      do: Roux.Blob.open!(Path.join(Mix.Project.build_path(), "argus/store")),
      else: Roux.Blob.temporary()
  end

  @doc """
  A database over the graph (`Argus.Graph`) with the environment set
  and `paths` as the program `:test`, priors off.

  Options: `store: :temporary` for a blob store of the database's own
  (a test that must see its solver run, not a solve kept from another
  test); `program:` another program's id; `specs_source:` where the
  specs of the modules the program calls are read from
  (`Argus.Specs.Source`), the code path without one.
  """
  @spec new_db(%{optional(module()) => String.t()}, keyword()) :: Roux.Database.t()
  def new_db(paths, opts \\ []) do
    store =
      case Keyword.get(opts, :store) do
        :temporary -> Roux.Blob.temporary()
        nil -> store()
        store -> store
      end

    session = Argus.Graph.open(store: store)
    db = session.db
    _moved = Argus.Graph.set_environment(db, Keyword.take(opts, [:specs_source]))
    program = Keyword.get(opts, :program, :test)
    :ok = Argus.Graph.set_priors(db, program, :off)
    sync!(db, paths, program)
    db
  end

  @doc """
  Brings the program's beams in line with `paths`: each beam's input
  set, the program's keys, and the beams no longer in it removed.
  """
  @spec sync!(Roux.Database.t(), %{optional(module()) => String.t()}, term()) :: :ok
  def sync!(db, paths, program \\ :test) do
    keys = Argus.Graph.set_program(db, program, Map.values(paths))

    for key <- Input.keys(db, :beam), key not in keys do
      :ok = GC.mark_input_removed(db, :beam, key)
    end

    :ok
  end

  @doc """
  Each analysis's solved output rows from the graph, each relation's
  sorted: `{:ok, rows}` or why it degraded.
  """
  @spec incremental(Database.t(), [atom()], term()) :: %{optional(atom()) => term()}
  def incremental(db, analyses, program \\ :test) do
    analyses
    |> Task.async_stream(
      fn analysis ->
        result =
          case Argus.Graph.Findings.results(db, program, analysis) do
            {:ok, rows} -> {:ok, sorted(rows)}
            error -> error
          end

        {analysis, result}
      end,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, entry} -> entry end)
  end

  defp sorted(rows), do: Map.new(rows, fn {relation, rows} -> {relation, Enum.sort(rows)} end)

  @doc """
  Each analysis's output rows the batch way: one argus extraction of
  every beam, then each analysis's rules over it — `Argus.Findings.run/2`'s
  path, the incremental graph's oracle.
  """
  @spec batch(%{optional(module()) => String.t()}, [atom()]) :: %{optional(atom()) => term()}
  def batch(paths, analyses) do
    {:ok, dir} = Argus.Analysis.extract_facts(Map.values(paths), analyses)

    try do
      analyses
      |> Task.async_stream(
        fn analysis ->
          result =
            case Argus.Analysis.run_rules(dir, analysis) do
              {:ok, rows} ->
                {:ok, rows |> Argus.Analysis.filter_to_outputs(analysis) |> sorted()}

              {:error, _} = error ->
                error
            end

          {analysis, result}
        end,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, entry} -> entry end)
    after
      File.rm_rf(Path.dirname(dir))
    end
  end
end
