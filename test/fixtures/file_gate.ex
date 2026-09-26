defmodule Argus.Test.FileGate do
  @moduledoc """
  A stand-in for the file server that holds a race open: every request
  a process of the VM makes of `file_server_2` goes through it to the
  real server, and at the requests a gate names it runs an action,
  after the real server has answered and before the caller sees the
  answer. A check-then-act race in the code under test then happens on
  every run: the gate is the other process, acting between the check
  and the act.

  Install it only in a VM of its own (`:peer`): while it is installed,
  every file operation of the VM goes through it. Operations the file
  server never sees (`:prim_file`, `File.touch/1`, `File` calls given
  `:raw`) pass it by.

  A gate is a map:

    * `:name` — what `uninstall/0` reports its action's result under;
    * `:ops` — the requests it watches (`:read_file_info`,
      `:read_link_info`, `:write_file_info`, `:read_file`, `:list_dir`,
      `:rename`, `:delete`, `:del_dir`, ...);
    * `:path` — the path they name (the first path of a rename);
    * `:prefix` — true to watch every path under `:path` as well;
    * `:nth` — which of the watched requests it acts at (default 1);
    * `:action` — `{module, function, args}`, run once, in a process
      of its own, so its own file operations go through the stand-in
      too (and past a gate that already acted).
  """

  @server :file_server_2

  @typedoc "See the moduledoc."
  @type gate :: %{
          required(:name) => term(),
          required(:ops) => [atom()],
          required(:path) => Path.t(),
          required(:action) => {module(), atom(), [term()]},
          optional(:prefix) => boolean(),
          optional(:nth) => pos_integer()
        }

  @doc "Puts the stand-in in front of the file server, with `gates`."
  @spec install([gate()]) :: :ok
  def install(gates) do
    real = Process.whereis(@server)
    gates = Enum.map(gates, &Map.merge(%{prefix: false, nth: 1, seen: 0, result: :not_run}, &1))
    stand_in = spawn(fn -> loop(real, gates) end)
    :persistent_term.put({__MODULE__, :stand_in}, stand_in)
    true = Process.unregister(@server)
    true = Process.register(stand_in, @server)
    :ok
  end

  @doc """
  Puts the real file server back, and returns each gate's action's
  result by name: `:not_run` for a gate whose request never came. With
  no stand-in in front of it, nothing (`%{}`).
  """
  @spec uninstall() :: %{term() => term()}
  def uninstall do
    stand_in = :persistent_term.get({__MODULE__, :stand_in}, nil)

    if stand_in != nil and Process.whereis(@server) == stand_in do
      ref = make_ref()
      send(stand_in, {__MODULE__, :uninstall, self(), ref})

      receive do
        {^ref, results} -> results
      end
    else
      %{}
    end
  end

  defp loop(real, gates) do
    receive do
      {:"$gen_call", from, request} = message ->
        case at_gate(request, gates) do
          {:act, gate, gates} ->
            stand_in = self()
            spawn(fn -> act(real, from, request, gate, stand_in) end)
            loop(real, gates)

          {:pass, gates} ->
            send(real, message)
            loop(real, gates)
        end

      {__MODULE__, :result, name, result} ->
        loop(real, Enum.map(gates, &if(&1.name == name, do: %{&1 | result: result}, else: &1)))

      {__MODULE__, :uninstall, caller, ref} ->
        true = Process.unregister(@server)
        true = Process.register(real, @server)
        send(caller, {ref, Map.new(gates, &{&1.name, &1.result})})

      other ->
        send(real, other)
        loop(real, gates)
    end
  end

  # The request answered by the real server, the action run, and only
  # then the answer handed to the caller.
  defp act(real, from, request, gate, stand_in) do
    reply = :gen_server.call(real, request, :infinity)
    {module, function, args} = gate.action
    send(stand_in, {__MODULE__, :result, gate.name, apply(module, function, args)})
    :gen_server.reply(from, reply)
  end

  # The first gate still to act that watches the request counts it, and
  # acts when it is the one it waits for.
  defp at_gate(request, gates) do
    {op, path} = describe(request)

    index =
      Enum.find_index(gates, fn gate ->
        gate.result == :not_run and op in gate.ops and path != nil and watches?(gate, path)
      end)

    case index do
      nil ->
        {:pass, gates}

      index ->
        gate = Enum.at(gates, index)
        gate = %{gate | seen: gate.seen + 1}

        if gate.seen == gate.nth do
          gate = %{gate | result: :running}
          {:act, gate, List.replace_at(gates, index, gate)}
        else
          {:pass, List.replace_at(gates, index, gate)}
        end
    end
  end

  defp watches?(%{path: watched, prefix: false}, path), do: path == watched

  defp watches?(%{path: watched, prefix: true}, path),
    do: path == watched or String.starts_with?(path, watched <> "/")

  defp describe(request) when is_tuple(request) and tuple_size(request) >= 2 do
    op = elem(request, 0)

    path =
      case elem(request, 1) do
        name when is_binary(name) or is_list(name) -> IO.chardata_to_string(name)
        _ -> nil
      end

    {op, path}
  rescue
    ArgumentError -> {nil, nil}
  end

  defp describe(_request), do: {nil, nil}
end
