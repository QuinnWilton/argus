defmodule Argus.Test.Peer do
  @moduledoc """
  A second BEAM for the tests that drive VM-wide state — the Mix project
  stack, the working directory, `PATH`, application env, telemetry
  handlers, the souffle scratch root — so those tests can run `async:
  true` beside each other instead of one at a time.

  Each peer is its own OS process, started from this VM's code path, with
  Mix started in the `:test` env and its own `TMPDIR`. A test module that
  `use`s this module can run its own closures there: the module's
  bytecode is kept when it compiles and loaded into the peer on first
  use, so `run/2` takes an ordinary `fn`, assertions and all. An
  exception raised in the peer is raised again here, with the peer's
  stacktrace.

  Everything a peer holds — processes, loaded fixture modules, the
  projects `Mix.Project.in_project/3` cached — goes with it: a peer per
  module isolates it from every other module exactly as a separate
  `mix` invocation would.
  """

  defmacro __using__(_opts) do
    quote do
      @after_compile Argus.Test.Peer
    end
  end

  @doc false
  def __after_compile__(env, bytecode) do
    :persistent_term.put({__MODULE__, env.module}, bytecode)
  end

  @doc """
  Starts a peer linked to the calling process and returns it. Call it
  from `setup_all` (one peer per module) or `setup` (one per test).

  The peer's graph runs keep their facts and solves in the suite's blob
  store (`ARGUS_CACHE_DIR`, as this VM's), unless `store: :own` gives it
  one of its own, removed with it: for a test that must see its solver
  run rather than a solve kept by another.
  """
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "argus_peer_#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    store =
      case Keyword.get(opts, :store) do
        :own -> Path.join(tmp, "store")
        nil -> Argus.Graph.store_root()
      end

    # No scheduler busy-waiting: a peer mostly waits on souffle, and a
    # dozen of them spinning at once take the CPU the solves need.
    args =
      [~c"+sbwt", ~c"none", ~c"+sbwtdcpu", ~c"none", ~c"+sbwtdio", ~c"none"] ++
        Enum.flat_map(code_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: args,
        env: [
          {~c"TMPDIR", String.to_charlist(tmp <> "/")},
          {~c"ARGUS_CACHE_DIR", String.to_charlist(store)}
        ],
        wait_boot: 60_000
      })

    :ok = call(peer, __MODULE__, :boot, [Code.compiler_options()])
    # Removed by `rm`, not `File.rm_rf/1`: that goes through the VM's
    # file server, which every test's `File` call queues behind, and a
    # peer's scratch of fact directories outlasted the callback's timeout
    # under a full suite's load.
    ExUnit.Callbacks.on_exit(fn -> System.cmd("rm", ["-rf", tmp]) end)
    peer
  end

  # The ebins of argus's runtime applications and of Mix and ExUnit —
  # what a project's `mix compile` has with argus as a dependency — and
  # not this VM's dev tools (credo, dialyxir, presubmit): the environment
  # fingerprint hashes every beam of a non-OTP application on the code
  # path, once per VM, and a peer is a fresh VM.
  defp code_path do
    [:panoptes, :mix, :ex_unit, :logger]
    |> applications([])
    |> Enum.flat_map(fn app ->
      case :code.lib_dir(app) do
        {:error, _} -> []
        dir -> [Path.join(List.to_string(dir), "ebin")]
      end
    end)
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&String.to_charlist/1)
  end

  defp applications([], seen), do: Enum.reverse(seen)

  defp applications([app | rest], seen) do
    if app in seen do
      applications(rest, seen)
    else
      # An optional application that is not installed has no spec.
      _ = Application.load(app)

      deps =
        List.wrap(Application.spec(app, :applications)) ++
          List.wrap(Application.spec(app, :included_applications))

      applications(deps ++ rest, [app | seen])
    end
  end

  @doc false
  # Runs in the peer: the apps a test here expects running, Mix in the
  # env `mix test` gives this VM (fixtures build under _build/test), and
  # this VM's compiler options (`mix test` compiles without debug info),
  # so a fixture compiles here as it would have there.
  def boot(compiler_options) do
    {:ok, _} = Application.ensure_all_started([:logger, :ex_unit, :mix, :telemetry])
    Mix.env(:test)
    Code.compiler_options(compiler_options)
    :ok
  end

  @doc """
  Runs `fun` in `peer` and returns its value. Logs are captured there
  and printed only when `fun` raises, as ExUnit's `capture_log` would.
  """
  @spec run(pid(), (-> result)) :: result when result: term()
  def run(peer, fun) when is_function(fun, 0), do: apply(peer, :erlang, :apply, [fun, []])

  @doc """
  `apply(module, function, args)` in `peer`, as `run/2` runs a closure:
  the module defining each closure among `args` is loaded there first.
  """
  @spec apply(pid(), module(), atom(), [term()]) :: term()
  def apply(peer, module, function, args) do
    args
    |> Enum.filter(&is_function/1)
    |> Enum.map(&(&1 |> Function.info(:module) |> elem(1)))
    |> Enum.uniq()
    |> Enum.each(&(:ok = call(peer, __MODULE__, :ensure_loaded, [&1, bytecode(&1)])))

    case call(peer, __MODULE__, :apply_logged, [module, function, args]) do
      {:ok, value} ->
        value

      {:raise, kind, reason, stacktrace, log} ->
        if log != "", do: IO.puts(:stderr, "\n[peer log]\n" <> log)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc false
  # A module on the shared code path (test/support) loads from there; a
  # test module, compiled in memory, from the bytecode kept for it.
  def ensure_loaded(module, bytecode) do
    case {:code.ensure_loaded(module), bytecode} do
      {{:module, ^module}, _} ->
        :ok

      {{:error, _}, nil} ->
        raise ArgumentError,
              "#{inspect(module)} has no bytecode to load into a peer: `use Argus.Test.Peer` in it"

      {{:error, _}, bytecode} ->
        {:module, ^module} = :code.load_binary(module, ~c"#{module}", bytecode)
        :ok
    end
  end

  @doc false
  def apply_logged(module, function, args) do
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        try do
          {:ok, Kernel.apply(module, function, args)}
        catch
          kind, reason -> {:raise, kind, reason, __STACKTRACE__}
        end
      end)

    case result do
      {:ok, _} = ok -> ok
      {:raise, kind, reason, stacktrace} -> {:raise, kind, reason, stacktrace, log}
    end
  end

  defp bytecode(module), do: :persistent_term.get({__MODULE__, module}, nil)

  # Test bodies are bounded by ExUnit's own timeout, not the call's.
  defp call(peer, module, function, args),
    do: :peer.call(peer, module, function, args, :infinity)
end
