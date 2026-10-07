defmodule Argus.Driver do
  @moduledoc """
  The run every frontend makes over a project: its beams set as the
  graph's program, the environment set, the analyses demanded, the
  graph kept for the next run (`Argus.Graph`).

  One session lives for the duration of a run (`Roux.Session`), opened
  from the project's manifest (`compile.argus` in its state directory)
  and committed back to it only when the run changed something: a warm
  run with nothing moved validates the graph and writes nothing. What a
  run computes lives in the blob store the manifest names by digest
  (`Argus.Graph.store/0`), shared by every project and worktree on the
  machine.

  The beams are synced with `Roux.Sources`: a beam whose size and
  modification time match the last run's is not read, unless it was
  written within the last two seconds (a fast edit-compile-edit can
  rewrite one in the same second with the same size); anything else is
  read and hashed without the chunks extraction never reads, so a beam
  Elixir rewrote only to refresh its type checker table moves nothing.
  The modules the `ignore` patterns keep out of analysis are synced too:
  never analyzed, but their specs are read by their callers'
  extraction, which depends on their beams.

  Without the engines (no Rust to build them: `Argus.FlowLog.available?/0`)
  nothing is solved: no analysis is demanded, and the result says so
  (`:engine_unavailable`). What failed is never kept — a
  solve that failed, a module extraction lost to a timeout, and every
  query that read one (`transient:`, `Roux.Query`) — so the next run
  tries it again.
  """

  alias Argus.Driver.Result
  alias Argus.Graph
  alias Roux.Input

  @program :project

  @typedoc """
  The project a run analyzes: where it is (`root`, the `project_root`
  input: where a beam compiled elsewhere finds its source) and where its
  state lives (`state_dir`, the manifest's directory). A frontend's
  project adapter builds it; a Mix project's is `mix_project/0`.
  """
  @type project :: %{
          required(:root) => Path.t(),
          required(:state_dir) => Path.t(),
          optional(atom()) => term()
        }

  @doc """
  The current Mix project (`Argus.Project.Mix.current/0`): its directory,
  its ebins, and its manifest path for state.
  """
  @spec mix_project() :: project()
  def mix_project, do: Argus.Project.Mix.current()

  @doc """
  The manifest the graph is kept in between runs, in the project's state
  directory: shared by `mix compile.argus` and `mix argus`, one
  incremental state whichever entry point drives it.
  """
  @spec manifest_file(project()) :: String.t()
  def manifest_file(project \\ mix_project()), do: Path.join(project.state_dir, "compile.argus")

  @doc "The files a run keeps in the project's state directory: the manifest."
  @spec state_files(project()) :: [String.t()]
  def state_files(project \\ mix_project()), do: [manifest_file(project)]

  @doc """
  Where scry's graph kept its hashes and programs beside the manifest.
  Nothing writes it now; a frontend's `clean` removes one a scry left.
  """
  @spec cache_dir() :: String.t()
  def cache_dir, do: Path.join(Mix.Project.manifest_path(), "compile.scry.cache")

  @doc """
  Runs the configured analyses against the project's compiled beams.

  ## Options

    * `:project` — the project (`t:project/0`: an `Argus.Project`, whose
      program's and dependencies' ebins the scan reads), default the
      current Mix project;
    * `:manifest` — the manifest to keep the graph in, default
      `manifest_file/1`;
    * `:store` — the blob store, default `Argus.Graph.store/0`;
    * `:force` — start cold, ignoring the manifest (it is written
      afresh).
  """
  @spec run(Argus.Config.t(), keyword()) :: Result.t()
  def run(%Argus.Config{} = config, opts) do
    project = Keyword.get_lazy(opts, :project, &mix_project/0)
    manifest = Keyword.get_lazy(opts, :manifest, fn -> manifest_file(project) end)
    force? = Keyword.get(opts, :force, false)

    session = Graph.open(store: Keyword.get(opts, :store), manifest: manifest, force: force?)
    # The session ends with the run, which solves each program once.
    :ok = Argus.FlowLog.Pool.keep(session.db.supervisor, false)

    try do
      db = session.db

      %{modules: discovered, ignored: ignored, duplicates: duplicates} =
        Argus.Project.Scan.scan(config, project)

      files =
        Map.new(Map.values(discovered) ++ Map.values(ignored), fn path ->
          path = Path.expand(path)
          {path, path}
        end)

      %{meta: meta} =
        Roux.Sources.sync(db, :beam, files, session.sources,
          hash: &Graph.hash/1,
          value: fn %{hash: hash} -> %{hash: hash} end
        )

      # A beam deleted between the scan and the sync is not part of the
      # project this run.
      keys =
        discovered
        |> Map.values()
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&Map.has_key?(meta, &1))
        |> Enum.sort()

      :ok = Input.set(db, :program, @program, keys)

      _moved =
        Graph.set_environment(db,
          project_root: project.root,
          # Every beam there is an input (`discovered` and `ignored`).
          own_ebins: Enum.map(project.apps, &elem(&1, 1)),
          # The specs of the modules the program calls are read from
          # the project's own ebins and the installed OTP, never from
          # the VM's code path.
          specs_source: Argus.Specs.Source.new(project)
        )

      solver? = Argus.FlowLog.available?()

      {located, notices} =
        if solver? do
          :ok = Graph.set_priors(db, @program, config.priors)
          located = Graph.located(db, @program, config.analyses)
          {located, extraction_notices(db, discovered) ++ points_to_notices(db)}
        else
          {%{}, [:engine_unavailable]}
        end

      {status, _session} = Roux.Session.commit(session, meta)
      _ = collect(session.blob)

      %Result{
        located: located,
        notices: notices ++ Enum.map(duplicates, &{:duplicate, &1}),
        changed?: force? or status == :written
      }
    after
      Roux.Session.close(session)
    end
  end

  # What extraction could not do: each module it could not read at all
  # (named as the scan found its beam: nothing in it says which module it
  # is), and each step it recorded as failing on a module.
  defp extraction_notices(db, discovered) do
    by_path = Map.new(discovered, fn {module, path} -> {Path.expand(path), module} end)

    for error <- Graph.Findings.extraction_errors(db, @program) do
      module = error.module || Map.get(by_path, error.source)
      name = if error.module == nil and module != nil, do: inspect(module), else: error.source

      {:extraction_error, %{module: module, name: name, step: error.step, reason: error.reason}}
    end
  end

  # The points-to stage ran bounded, when an analysis read it: the
  # leaves its coarse pass resolved.
  defp points_to_notices(db) do
    case Roux.Memo.get(db, {:stage, {@program, :points_to}}) do
      {:ok, %Roux.Memo.Entry{value: {:ok, %{mode: {:bounded, leaves}}}}} ->
        [{:points_to_bounded, leaves}]

      _ ->
        []
    end
  end

  # The store, collected when a day has passed since its last collection
  # and no other run is collecting it (`Roux.Blob.maybe_gc/2`): what no
  # manifest retains, untouched for a day, and traces and kept solves
  # unused for a week. Every frontend runs here, so a store in use is
  # collected by the runs that use it; a temporary one goes as it
  # closes.
  defp collect(%Roux.Blob{temporary?: true}), do: :skipped
  defp collect(%Roux.Blob{} = store), do: Roux.Blob.maybe_gc(store)
end
