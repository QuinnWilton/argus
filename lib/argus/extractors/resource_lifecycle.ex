defmodule Argus.Extractors.ResourceLifecycle do
  @moduledoc """
  Resource lifecycle extractor.

  Detects resource open and close operations for files, sockets, and ports.
  BEAM's garbage collector does not reliably close file descriptors, so
  resources opened but not closed on all paths leak. Long-running services
  accumulate leaked FDs until they hit OS limits.

  ## Emitted facts

  - `resource_open(id, func, type)` — `File.open`, `:gen_tcp.connect`, `Port.open`, etc.
  - `resource_close(id, func, type)` — `File.close`, `:gen_tcp.close`, `Port.close`, etc.
  - `port_open(id, func, port_type)` — `:erlang.open_port/2` with port type
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  # Resource open APIs mapped to their resource type.
  @open_apis %{
    {File, :open, 1} => "file",
    {File, :open, 2} => "file",
    {:file, :open, 2} => "file",
    {:file, :read_file, 1} => "file",
    {:gen_tcp, :connect, 3} => "socket",
    {:gen_tcp, :connect, 4} => "socket",
    {:gen_tcp, :listen, 2} => "socket",
    {:gen_udp, :open, 1} => "socket",
    {:gen_udp, :open, 2} => "socket",
    {:ssl, :connect, 2} => "socket",
    {:ssl, :connect, 3} => "socket",
    {:ssl, :connect, 4} => "socket",
    {:ssl, :listen, 2} => "socket",
    {Port, :open, 2} => "port"
  }

  # Resource close APIs mapped to their resource type.
  @close_apis %{
    {File, :close, 1} => "file",
    {:file, :close, 1} => "file",
    {:gen_tcp, :close, 1} => "socket",
    {:gen_udp, :close, 1} => "socket",
    {:ssl, :close, 1} => "socket",
    {:ssl, :close, 2} => "socket",
    {Port, :close, 1} => "port",
    {:erlang, :port_close, 1} => "port"
  }

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    functions = module_data.functions

    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_instructions(facts, func_id, instrs)
    end)
  end

  defp scan_instructions(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, :erlang, :open_port, 2} ->
          id = "#{func_id}##{idx}"
          port_type = resolve_port_type(instrs, idx)

          acc
          |> add_fact(:port_open, [id, func_id, port_type])
          |> add_fact(:resource_open, [id, func_id, "port"])

        {:ok, mod, func, arity} ->
          id = "#{func_id}##{idx}"

          acc
          |> maybe_open(id, func_id, mod, func, arity)
          |> maybe_close(id, func_id, mod, func, arity)

        :none ->
          acc
      end
    end)
  end

  defp maybe_open(facts, id, func_id, mod, func, arity) do
    case Map.get(@open_apis, {mod, func, arity}) do
      nil -> facts
      type -> add_fact(facts, :resource_open, [id, func_id, type])
    end
  end

  defp maybe_close(facts, id, func_id, mod, func, arity) do
    case Map.get(@close_apis, {mod, func, arity}) do
      nil -> facts
      type -> add_fact(facts, :resource_close, [id, func_id, type])
    end
  end

  # Resolve the port type from the first argument to :erlang.open_port/2.
  # Port types are {:spawn, cmd}, {:spawn_executable, path}, {:spawn_driver, drv},
  # or {:fd, in, out}.
  defp resolve_port_type(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, {:spawn, _}} -> "spawn"
      {:ok, {:spawn_executable, _}} -> "spawn_executable"
      {:ok, {:spawn_driver, _}} -> "spawn_driver"
      {:ok, {:fd, _, _}} -> "fd"
      _ -> "dynamic"
    end
  end
end
