defmodule Argus.Extractors.Endpoint do
  @moduledoc """
  Which socket transports a Phoenix endpoint actually enables.

  Configuration is often assumed to be invisible to a bytecode analysis, and
  for `Application.get_env/2` at runtime it is. `Phoenix.Endpoint`'s
  `socket/3` is a **macro**, so its options are compiled into the module —
  `__sockets__/0` is a single literal:

      {:move, {:literal, [
        {"/live", Phoenix.LiveView.Socket,
          [websocket: [...], longpoll: [connect_info: [...]]]}]}, {:x, 0}}
      :return

  That is the difference between a finding a human has to check against
  `endpoint.ex` and one the analysis settles itself. The long-poll transport
  starts a process per unauthenticated request with no ceiling, and it was
  reported in three projects while being enabled in one.

  A transport counts as enabled when its key is present and not `false`,
  which is how `Phoenix.Endpoint` reads it.

  ## Emitted facts

  - `socket_transport(endpoint, path, transport)` — an enabled transport
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @transports [:websocket, :longpoll]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    case Enum.find(functions, &match?({:function, :__sockets__, 0, _, _}, &1)) do
      nil -> %{}
      {:function, _, _, _, instrs} -> emit(inspect(mod), sockets(instrs))
    end
  end

  defp sockets(instrs) do
    Enum.find_value(instrs, [], fn
      {:move, {:literal, list}, {:x, 0}} when is_list(list) -> list
      _ -> false
    end)
  end

  defp emit(endpoint, sockets) do
    for {path, _socket_mod, opts} when is_binary(path) and is_list(opts) <- sockets,
        transport <- @transports,
        enabled?(opts, transport),
        reduce: %{} do
      facts -> add_fact(facts, :socket_transport, [endpoint, path, Atom.to_string(transport)])
    end
  end

  # Present and not false. `Phoenix.Endpoint` treats a missing key and an
  # explicit `false` the same way, and so does this.
  defp enabled?(opts, transport) do
    case Keyword.fetch(opts, transport) do
      :error -> false
      {:ok, false} -> false
      {:ok, _} -> true
    end
  end
end
