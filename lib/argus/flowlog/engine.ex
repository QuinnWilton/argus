defmodule Argus.FlowLog.Engine do
  @moduledoc """
  One running engine: a FlowLog program's dataflow in an OS process of
  its own, owned by this process through a port.

  The port is opened without stdio (`:nouse_stdio`): requests go out on
  the engine's descriptor 3 and replies come back on 4, as 4-byte
  length-prefixed JSON objects, so nothing the engine's runtime prints
  can be read as a reply. The engine logs to a file in the toolchain's
  `logs/` directory, which an error report names.

  The engine ends when the port closes: when this process stops, when it
  is killed (a commit that outlived its timeout), and when the VM exits
  by any means, a SIGKILL included. A reader thread in the engine watches
  the request descriptor, so even a commit still computing is abandoned.

  `start_link/1` checks the engine before handing it out: it must speak
  the protocol argus speaks and must have been built from the program
  digest argus asked for (`hello`). A stale engine, or one built from
  other sources, is refused.

  An engine holds every input relation's rows as of its last commit.
  `commit/3` names the inputs that changed, each by a file of all its
  rows (`Argus.Tsv`); the engine diffs, applies the difference as one
  epoch, and writes each output whose rows changed into the commit's
  output directory. This process remembers what each input was last
  committed as (`snapshot/1`), so a caller sends only the relations whose
  identity moved.

  ## Telemetry

    * `[:argus, :flowlog, :engine, :start]` — an engine started and
      answered `hello`: `%{duration: native_time}`, `%{digest: digest}`;
    * `[:argus, :flowlog, :engine, :commit]` — a commit the engine
      answered: `%{duration: native_time}`, `%{digest: digest, inputs:
      count, written: count}` (the inputs it was told of, the outputs it
      wrote).
  """

  use GenServer

  @protocol 1

  @typedoc "An engine process."
  @type t :: pid()

  @typedoc "What a commit reports."
  @type commit_result :: %{
          epoch: non_neg_integer(),
          written: [String.t()],
          sizes: %{String.t() => non_neg_integer()},
          inputs: %{String.t() => map()},
          micros: map()
        }

  # ── Client ───────────────────────────────────────────────────────────

  @doc """
  Starts an engine and checks it. Options:

    * `:executable` (required) — the engine binary;
    * `:args` — what it is run with before the host's own flags: the
      generic engine's `serve` and its program (default none);
    * `:digest` (required) — the program digest it must report;
    * `:workers` — dataflow worker threads (default 1);
    * `:log` — the file the engine logs to.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Commits `inputs` (`%{relation => path}`), writing changed outputs into
  `out_dir`; `identities` (`%{relation => term}`) are what this process
  remembers the inputs as afterwards. A commit that does not finish
  within `timeout` kills the engine and is `{:error, :flowlog_timeout}`.
  """
  @spec commit(
          t(),
          Path.t(),
          %{String.t() => Path.t()},
          %{String.t() => term()},
          timeout(),
          keyword()
        ) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(engine, out_dir, inputs, identities, timeout, opts \\ []) do
    GenServer.call(
      engine,
      {:commit, out_dir, inputs, identities, Keyword.get(opts, :rewrite, false)},
      call_timeout(timeout)
    )
  catch
    :exit, {:timeout, _} ->
      stop(engine)
      {:error, :flowlog_timeout}

    :exit, {reason, _} ->
      {:error, {:flowlog_engine_down, reason}}
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout), do: timeout

  @doc """
  What each input was last committed as (`%{relation => identity}`) and
  the outputs as last recorded (`put_outputs/2`), or an error when the
  engine is down.
  """
  @spec snapshot(t()) ::
          {:ok, {%{String.t() => term()}, %{String.t() => term()}}} | {:error, term()}
  def snapshot(engine) do
    GenServer.call(engine, :snapshot, :infinity)
  catch
    :exit, {reason, _} -> {:error, {:flowlog_engine_down, reason}}
  end

  @doc "Records `outputs` as the engine's current outputs."
  @spec put_outputs(t(), %{String.t() => term()}) :: :ok
  def put_outputs(engine, outputs), do: GenServer.call(engine, {:put_outputs, outputs}, :infinity)

  @doc "The engine's OS process id, for diagnostics."
  @spec os_pid(t()) :: non_neg_integer() | nil
  def os_pid(engine), do: GenServer.call(engine, :os_pid, :infinity)

  @doc "The manifest the engine reported at `hello`."
  @spec manifest(t()) :: map()
  def manifest(engine), do: GenServer.call(engine, :manifest, :infinity)

  @doc """
  Stops the engine (and its OS process, as its port closes). Unlinks it
  first: the caller that started it outlives it.
  """
  @spec stop(t()) :: :ok
  def stop(engine) do
    Process.unlink(engine)
    Process.exit(engine, :kill)
    :ok
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    started = System.monotonic_time()
    executable = Keyword.fetch!(opts, :executable)
    digest = Keyword.fetch!(opts, :digest)
    workers = Keyword.get(opts, :workers, 1)

    args =
      Keyword.get(opts, :args, []) ++
        ["--workers", Integer.to_string(workers)] ++
        case Keyword.get(opts, :log) do
          nil -> []
          log -> ["--log", log]
        end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :nouse_stdio,
        :exit_status,
        {:packet, 4},
        args: args
      ])

    state = %{
      port: port,
      log: Keyword.get(opts, :log),
      digest: digest,
      held: %{},
      outputs: %{},
      manifest: nil
    }

    case request(state, %{op: "hello"}, 30_000) do
      {:ok, %{"protocol" => @protocol, "digest" => ^digest} = hello} ->
        :telemetry.execute(
          [:argus, :flowlog, :engine, :start],
          %{duration: System.monotonic_time() - started},
          %{digest: digest}
        )

        {:ok, %{state | manifest: hello}}

      {:ok, %{"protocol" => @protocol, "digest" => other}} ->
        Port.close(port)
        {:stop, {:flowlog_stale_engine, executable, digest, other}}

      {:ok, %{"protocol" => other}} ->
        Port.close(port)
        {:stop, {:flowlog_protocol, executable, @protocol, other}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:commit, out_dir, inputs, identities, rewrite}, _from, state) do
    request = %{op: "commit", out: out_dir, inputs: inputs, rewrite: rewrite}
    started = System.monotonic_time()

    case request(state, request, :infinity) do
      {:ok, reply} ->
        :telemetry.execute(
          [:argus, :flowlog, :engine, :commit],
          %{duration: System.monotonic_time() - started},
          %{digest: state.digest, inputs: map_size(inputs), written: length(reply["written"])}
        )

        result = %{
          epoch: reply["epoch"],
          written: reply["written"],
          sizes: reply["sizes"],
          inputs: reply["inputs"],
          micros: reply["micros"]
        }

        {:reply, {:ok, result}, %{state | held: Map.merge(state.held, identities)}}

      {:error, {:flowlog_engine_exit, _, _} = reason} ->
        {:stop, :normal, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, {:ok, {state.held, state.outputs}}, state}

  def handle_call({:put_outputs, outputs}, _from, state),
    do: {:reply, :ok, %{state | outputs: outputs}}

  def handle_call(:manifest, _from, state), do: {:reply, state.manifest, state}

  def handle_call(:os_pid, _from, state) do
    os_pid =
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:reply, os_pid, state}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:flowlog_engine_exit, status, log_tail(state.log)}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One request and its reply. The engine answers requests in order, one
  # at a time, and only this process talks to it.
  defp request(%{port: port} = state, request, timeout) do
    Port.command(port, :json.encode(request))

    receive do
      {^port, {:data, data}} ->
        case :json.decode(data) do
          %{"ok" => true} = reply ->
            {:ok, reply}

          %{"ok" => false, "kind" => kind, "message" => message} ->
            {:error, {:flowlog_error, kind, message}}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:flowlog_engine_exit, status, log_tail(state.log)}}
    after
      timeout -> {:error, :flowlog_timeout}
    end
  end

  defp log_tail(nil), do: ""

  defp log_tail(log) do
    case File.read(log) do
      {:ok, text} -> text |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n")
      {:error, _} -> ""
    end
  end
end
