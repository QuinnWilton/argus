defmodule Scry.Test.Fixture do
  @moduledoc """
  Checks out the fixture project under `test/fixtures/depot` with scry
  appended to its compilers, so the full `mix compile` chain —
  `:elixir` producing beams, `:scry` analyzing them — runs against a
  real project with known findings.

  Goldens for the pristine checkout, from the default analysis set:
  `coupling: 1` (Sonar listens on Notifier from handle_continue/2 and
  Notifier keeps the listener in its state; anchored at the tree
  definition in application.ex; Queue's notify on each use holds
  nothing), `mailbox: 2` (the leaked task in archive.ex and the linked
  task the same module starts in library code), nothing else. Sonar's
  handle_info/2 has no catch-all, which is no finding by itself: nothing
  writes its mailbox that it does not take (its registration brings only
  `{:depot_event, :health, _}`, which it takes, and its outside calls are
  timed `GenServer.call`s, whose late replies an alias drops).

  The scry compiler task itself is resolved from this test VM's code
  path (the host app's, which a peer starts from), so the fixture needs
  no dependency on scry.
  """

  import ExUnit.CaptureIO, only: [with_io: 1, with_io: 2]

  alias Scry.Test.{Peer, QueryLog}

  @fixture Path.expand("../fixtures/depot", __DIR__)

  # The module namespaces the fixture projects define. A fixture compiled
  # earlier in this VM leaves its modules loaded, and compiling another
  # checkout of the same sources would warn that each is redefined.
  @fixture_namespaces ["Elixir.Depot.", "Elixir.A.", "Elixir.B."]

  @doc """
  Copies the fixture into `dest` (wiped first) and returns `dest`.

  `scry_config` is rendered into the fixture's `scry:` project keyword.
  `app` must be UNIQUE per distinct config in one test VM:
  `Mix.Project.in_project/3` caches loaded projects by app atom, so two
  fixtures sharing an app name silently share the first one's config.
  """
  @spec checkout!(Path.t(), keyword(), atom()) :: Path.t()
  def checkout!(dest, scry_config \\ [], app \\ :depot) do
    unload!()
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    File.cp_r!(Path.join(@fixture, "lib"), Path.join(dest, "lib"))
    write_mix_exs!(dest, scry_config, app)
    dest
  end

  @doc """
  Runs the full compile chain in the current project, repeatably, with
  its console output captured: `Mix.Task.clear/0` re-enables the nested
  compile tasks between runs, `--return-errors` keeps an `:error` status
  from exiting the VM, and `--no-prune-code-paths` keeps this test VM's
  own apps (scry and its deps) loadable inside the fixture — a real
  project gets that for free from its scry dependency.

  The rendered frames go to stderr; the diagnostics come back in the
  result, which is what tests assert on. `compile_io!/0` returns the
  output too.
  """
  @spec compile!() :: {Mix.Task.Compiler.status(), [Mix.Task.Compiler.Diagnostic.t()]}
  def compile! do
    {result, _stderr} = compile_io!()
    result
  end

  @doc "`compile!/0`, also returning what the chain printed to stderr."
  @spec compile_io!() ::
          {{Mix.Task.Compiler.status(), [Mix.Task.Compiler.Diagnostic.t()]}, String.t()}
  def compile_io! do
    Mix.Task.clear()

    with_io(:stderr, fn ->
      {result, _stdout} =
        with_io(fn ->
          Mix.Task.run("compile", ["--return-errors", "--no-prune-code-paths"])
        end)

      result
    end)
  end

  @doc """
  Runs `fun` inside the checked-out fixture at `copy` (as `app`), in
  `peer` (`Scry.Test.Peer`), with this peer's earlier fixture modules
  unloaded and a `Scry.Test.QueryLog` started for the call: `fun` takes
  the log and its value comes back.
  """
  @spec in_peer(pid(), Path.t(), atom(), (pid() -> result)) :: result when result: term()
  def in_peer(peer, copy, app, fun) when is_function(fun, 1) do
    Peer.apply(peer, __MODULE__, :in_project_logged, [copy, app, fun])
  end

  @doc false
  def in_project_logged(copy, app, fun) do
    unload!()
    log = QueryLog.start()

    try do
      Mix.Project.in_project(app, copy, fn _module -> fun.(log) end)
    after
      QueryLog.detach(log)
    end
  end

  @doc """
  Purges every loaded fixture module, so the next checkout compiles its
  own copies without redefinition warnings.
  """
  @spec unload!() :: :ok
  def unload! do
    for {module, _file} <- :code.all_loaded(),
        name = Atom.to_string(module),
        Enum.any?(@fixture_namespaces, &String.starts_with?(name, &1)),
        # The project module stays: in_project caches it by app atom.
        not String.ends_with?(name, ".MixProject") do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end

  @doc """
  Rewrites the fixture's mix.exs with a different `scry:` config
  (between runs of an already-checked-out fixture).
  """
  @spec write_mix_exs!(Path.t(), keyword(), atom()) :: :ok
  def write_mix_exs!(dest, scry_config, app \\ :depot) do
    File.write!(Path.join(dest, "mix.exs"), """
    defmodule #{Macro.camelize(to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(app)},
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: false,
          compilers: Mix.compilers() ++ [:scry],
          scry: #{inspect(scry_config, limit: :infinity)},
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger], mod: {Depot.Application, []}]
      end
    end
    """)

    :ok
  end
end
