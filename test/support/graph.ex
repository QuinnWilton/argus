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
  A database with both layers registered and the driver's inputs set
  the way `Argus.Driver` sets them, over `paths`.

  Options: `rules: false` and `argus: false` leave the rules digests and
  argus's code digests (`:extraction_code`, `:argus_code`) unset, as
  planchette does.
  """
  @spec new_db(%{optional(module()) => String.t()}, keyword()) :: Database.t()
  def new_db(paths, opts \\ []) do
    db = Database.new()
    :ok = Roux.Lang.register_module(db, Argus.Graph.Frontend)
    :ok = Roux.Lang.register_module(db, Argus.Graph)
    :ok = Input.set(db, :env_fingerprint, :all, Keyword.get(opts, :fingerprint, %{test: 1}))
    :ok = Input.set(db, :project_root, :all, File.cwd!())

    # A frontend may leave the rules digests unset (planchette does).
    if Keyword.get(opts, :rules, true) do
      {:ok, all} = Argus.Analysis.set(:all)

      for {key, digest} <- Argus.Graph.Environment.rules(all),
          do: :ok = Input.set(db, :rules_digest, key, digest)
    end

    # And argus's code (planchette does).
    if Keyword.get(opts, :argus, true) do
      :ok = Input.set(db, :extraction_code, :all, Argus.Graph.Environment.extraction_code())
      :ok = Input.set(db, :argus_code, :all, Argus.Graph.Environment.argus_code())
    end

    Enum.each(Argus.Graph.prior_relations(), &(:ok = Input.set(db, :prior_rows, &1, [])))
    sync!(db, paths)
    db
  end

  @doc """
  Brings the database's beam inputs in line with `paths`: new and
  changed beams set, missing ones marked removed.
  """
  @spec sync!(Database.t(), %{optional(module()) => String.t()}) :: :ok
  def sync!(db, paths) do
    for {module, path} <- paths do
      canonical = path |> File.read!() |> Argus.Graph.Beam.canonical()
      :ok = Input.set(db, :beam_meta, module, %{path: path, hash: :erlang.md5(canonical)})
    end

    for module <- Input.keys(db, :beam_meta), not Map.has_key?(paths, module) do
      :ok = GC.mark_input_removed(db, :beam_meta, module)
    end

    :ok = Input.set(db, :module_set, :all, paths |> Map.keys() |> Enum.sort())
  end

  @doc """
  Each analysis's solved output rows from the incremental graph.
  """
  @spec incremental(Database.t(), [atom()]) :: %{optional(atom()) => term()}
  def incremental(db, analyses) do
    # As the runner demands them: the merged relations first, here, then
    # the solves side by side — they share everything upstream.
    _relations = Argus.Graph.program_relation_facts(db, :all)

    analyses
    |> Task.async_stream(&{&1, Argus.Graph.souffle_solve(db, &1)}, timeout: :infinity)
    |> Map.new(fn {:ok, entry} -> entry end)
  end

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
                {:ok,
                 rows
                 |> Argus.Analysis.filter_to_outputs(analysis)
                 |> Map.new(fn {relation, rows} -> {relation, Enum.sort(rows)} end)}

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
