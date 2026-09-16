defmodule Argus.Extractors.ApiCalls do
  @moduledoc """
  Calls to known APIs, classified by a table.

  Most of what the domain extractors record is one shape: a remote call
  to a function on a fixed list, with one or two of its arguments read
  back as a literal, and a row that says which API it was. Five
  extractors each kept such a list and each walked the module to apply
  it; the lists lived in module attributes, inline function heads and
  `MapSet`s, and encoded "infinity" three different ways. This one table
  holds them all, and the readers — the resolved target module, an atom
  argument, a timeout, a port target — are named once.

  An entry is `{{mod, fun, arity}, relation, columns}`; `arity` may be a
  list, and `fun` may be `:any` to match every function of a module.
  Columns are readers (see `read/4`): `:id`, `:func`, `:api`, `:fun`,
  `:arity`, `{:const, value}`, `{:module_target, n}`, `{:atom, n,
  category}`, `{:timeout, n, category}`, and a few domain readers. A
  reader that resolves to `"dynamic"` records the imprecision under its
  category, exactly as the extractors it replaces did.

  ## Emitted facts

  - `sync_call`, `sync_call_timeout`, `async_cast`, `sup_call` — process
    calls (GenServer, gen_statem, GenStage, Agent, gen_event, supervisors)
  - `unsafe_atom_creation`, `unsafe_deserialization`, `code_execution`
  - `port_open`
  - `rpc_call`, `global_register`, `global_op`, `node_operation`,
    `distributed_store_op`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      module_target: 3,
      resolve_atom: 3,
      resolve_register: 3,
      timeout_ms: 3,
      track_dynamic: 5,
      track_imprecision: 4
    ]

  # ── The table ──────────────────────────────────────────────────────────

  @sync_default_5000 [
    {GenServer, :call, 2},
    {:gen_server, :call, 2},
    {GenStage, :call, 2},
    {Agent, :get, 2},
    {Agent, :update, 2},
    {Agent, :get_and_update, 2}
  ]

  # A gen_statem client that omits the timeout waits forever.
  @sync_default_infinity [
    {:gen_statem, :call, 2},
    {GenStateMachine, :call, 2},
    {GenServer, :multi_call, [2, 3, 4]}
  ]

  @sync_explicit_timeout [
    {GenServer, :call, 3},
    {:gen_server, :call, 3},
    {:gen_statem, :call, 3},
    {GenStateMachine, :call, 3},
    {GenStage, :call, 3},
    {Agent, :get, 3},
    {Agent, :update, 3},
    {Agent, :get_and_update, 3}
  ]

  @async [
    {GenServer, :cast, 2},
    {:gen_server, :cast, 2},
    {:gen_statem, :cast, 2},
    {GenStateMachine, :cast, 2},
    {GenStage, :cast, 2}
  ]

  # Every one is a GenServer.call into the supervisor — start_child waits
  # for the child's init/1, terminate_child for its whole shutdown — but
  # none names a GenServer module. The supervisor argument is {x,0}.
  @sup_calls [
    {Supervisor, :start_child, 2},
    {Supervisor, :terminate_child, 2},
    {Supervisor, :restart_child, 2},
    {Supervisor, :delete_child, 2},
    {Supervisor, :which_children, 1},
    {Supervisor, :count_children, 1},
    {Supervisor, :stop, [1, 2, 3]},
    {DynamicSupervisor, :start_child, 2},
    {DynamicSupervisor, :terminate_child, 2},
    {DynamicSupervisor, :which_children, 1},
    {DynamicSupervisor, :count_children, 1},
    {DynamicSupervisor, :stop, [1, 2, 3]},
    {Task.Supervisor, :start_child, [2, 3]},
    {Task.Supervisor, :async, [2, 3, 4]},
    {Task.Supervisor, :async_nolink, [2, 3, 4]},
    {Task.Supervisor, :terminate_child, 2},
    {Task.Supervisor, :children, 1},
    {PartitionSupervisor, :which_children, 1},
    {PartitionSupervisor, :count_children, 1}
  ]

  @node_ops [
    {Node, :connect, 1},
    {Node, :disconnect, 1},
    {Node, :spawn, [2, 3, 4, 5]},
    {Node, :spawn_link, [2, 3, 4, 5]},
    {Node, :ping, 1},
    {Node, :list, [0, 1]},
    {Node, :monitor, 2},
    {:net_kernel, :connect_node, 1},
    {:net_kernel, :monitor_nodes, [1, 2]}
  ]

  @mnesia_ops ~w(read write delete delete_object first next last prev match_object select
                 index_read dirty_read dirty_write dirty_delete dirty_first dirty_next
                 dirty_last dirty_match_object dirty_index_read transaction activity
                 sync_transaction async_dirty sync_dirty create_table delete_table
                 add_table_index add_table_copy change_table_copy_type)a

  @dets_ops ~w(open_file close lookup insert delete match_object select first next sync info)a

  @table ((for mfa <- @sync_default_5000 do
             [
               {mfa, :sync_call, [:func, {:module_target, 0}]},
               {mfa, :sync_call_timeout, [:func, {:module_target, 0}, {:const, "5000"}]}
             ]
           end) ++
            (for mfa <- @sync_default_infinity do
               [
                 {mfa, :sync_call, [:func, {:module_target, 0}]},
                 {mfa, :sync_call_timeout, [:func, {:module_target, 0}, {:const, "-1"}]}
               ]
             end) ++
            (for mfa <- @sync_explicit_timeout do
               [
                 {mfa, :sync_call, [:func, {:module_target, 0}]},
                 {mfa, :sync_call_timeout,
                  [:func, {:module_target, 0}, {:timeout, 2, :sync_call_timeout}]}
               ]
             end) ++
            for(mfa <- @async, do: [{mfa, :async_cast, [:func, {:module_target, 0}]}]))
         |> List.flatten()
         |> Kernel.++([
           {{:gen_event, :sync_notify, 2}, :sync_call, [:func, {:atom, 0, :genserver_callee}]},
           {{:gen_event, :call, [3, 4]}, :sync_call, [:func, {:atom, 0, :genserver_callee}]},
           {{:gen_event, :notify, 2}, :async_cast, [:func, {:atom, 0, :genserver_callee}]}
         ])
         |> Kernel.++(
           for mfa <- @sup_calls,
               do: {mfa, :sup_call, [:id, :func, :mod, :fun, {:supervisor_target, 0}]}
         )
         |> Kernel.++([
           # ── atom safety ──
           {{String, :to_atom, 1}, :unsafe_atom_creation, [:id, :func, :api]},
           {{:erlang, :binary_to_atom, [1, 2]}, :unsafe_atom_creation, [:id, :func, :api]},
           {{:erlang, :list_to_atom, 1}, :unsafe_atom_creation, [:id, :func, :api]},
           {{:erlang, :binary_to_term, 1}, :unsafe_deserialization,
            [:id, :func, :api, {:const, "unsafe"}]},
           {{:erlang, :binary_to_term, 2}, :unsafe_deserialization,
            [:id, :func, :api, {:deserialization_safety, 1}]},
           {{Plug.Crypto, :non_executable_binary_to_term, :any}, :unsafe_deserialization,
            [:id, :func, :mod_fun, {:const, "validated"}]},
           {{Plug.Crypto, :safe_binary_to_term, :any}, :unsafe_deserialization,
            [:id, :func, :mod_fun, {:const, "validated"}]},
           {{Code, :eval_string, [1, 2, 3]}, :code_execution, [:id, :func, :api]},
           {{Code, :compile_string, [1, 2]}, :code_execution, [:id, :func, :api]},
           {{:os, :cmd, [1, 2]}, :code_execution, [:id, :func, :api]},
           {{System, :shell, [1, 2]}, :code_execution, [:id, :func, :api]},
           # System.cmd with a literal command and literal args runs a known
           # program; only a dynamic one is code execution.
           {{System, :cmd, [2, 3]}, :code_execution, [:id, :func, :api, :unless_static_command]},
           # ── ports ──
           {{Port, :open, 2}, :port_open, [:id, :func, {:const, "Port.open"}, {:port_target, 0}]},
           {{:erlang, :open_port, 2}, :port_open,
            [:id, :func, {:const, "erlang.open_port"}, {:port_target, 0}]},
           {{System, :cmd, [2, 3]}, :port_open,
            [:id, :func, {:const, "System.cmd"}, {:command, 0}]},
           {{System, :shell, [1, 2]}, :port_open,
            [:id, :func, {:const, "System.shell"}, {:command, 0}]},
           {{:os, :cmd, [1, 2]}, :port_open, [:id, :func, {:const, "os.cmd"}, {:command, 0}]},
           # ── distributed ──
           {{:rpc, :call, 4}, :rpc_call, [:id, :func, {:const, "rpc"}, {:const, "-1"}]},
           {{:rpc, :call, 5}, :rpc_call,
            [:id, :func, {:const, "rpc"}, {:timeout, 4, :rpc_timeout}]},
           {{:rpc, :multicall, [2, 3, 4]}, :rpc_call,
            [:id, :func, {:const, "multicall"}, {:const, "-1"}]},
           {{:rpc, :multicall, 5}, :rpc_call,
            [:id, :func, {:const, "multicall"}, {:timeout, 4, :rpc_timeout}]},
           {{:erpc, :call, 4}, :rpc_call,
            [:id, :func, {:const, "erpc"}, {:timeout, 3, :rpc_timeout}]},
           {{:erpc, :call, 5}, :rpc_call,
            [:id, :func, {:const, "erpc"}, {:timeout, 4, :rpc_timeout}]},
           {{:erpc, :multicall, 4}, :rpc_call,
            [:id, :func, {:const, "erpc_multicall"}, {:timeout, 3, :rpc_timeout}]},
           {{:erpc, :multicall, 5}, :rpc_call,
            [:id, :func, {:const, "erpc_multicall"}, {:timeout, 4, :rpc_timeout}]},
           {{:global, :register_name, [2, 3]}, :global_register,
            [:id, :func, {:atom, 0, :global_register_name}, :arity]},
           {{:global, :set_lock, 2}, :global_op,
            [:id, :func, {:const, "set_lock"}, {:const, "infinity"}]},
           {{:global, :set_lock, 3}, :global_op,
            [:id, :func, {:const, "set_lock"}, {:retries, 2}]},
           {{:global, :del_lock, [1, 2]}, :global_op,
            [:id, :func, {:const, "del_lock"}, {:const, "0"}]},
           {{:global, :trans, [2, 3]}, :global_op,
            [:id, :func, {:const, "trans"}, {:const, "infinity"}]},
           {{:global, :trans, 4}, :global_op, [:id, :func, {:const, "trans"}, {:retries, 3}]},
           {{:global, :whereis_name, 1}, :global_op,
            [:id, :func, {:const, "whereis_name"}, {:const, "0"}]},
           {{:global, :send, 2}, :global_op, [:id, :func, {:const, "send"}, {:const, "0"}]}
         ])
         |> Kernel.++(for mfa <- @node_ops, do: {mfa, :node_operation, [:id, :func, :fun]})
         |> Kernel.++(
           for op <- @mnesia_ops,
               do:
                 {{:mnesia, op, :any}, :distributed_store_op,
                  [:id, :func, {:const, "mnesia"}, :fun]}
         )
         |> Kernel.++(
           for op <- @dets_ops,
               do:
                 {{:dets, op, :any}, :distributed_store_op, [:id, :func, {:const, "dets"}, :fun]}
         )

  # Indexed by {mod, fun} at compile time; arity is checked per entry.
  @by_mod_fun Enum.group_by(@table, fn {{m, f, _a}, _rel, _cols} -> {m, f} end)

  @impl true
  def relations,
    do: [
      :async_cast,
      :code_execution,
      :distributed_store_op,
      :global_op,
      :global_register,
      :node_operation,
      :port_open,
      :rpc_call,
      :sup_call,
      :sync_call,
      :sync_call_timeout,
      :unsafe_atom_creation,
      :unsafe_deserialization
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    each_remote_call(module_data, %{}, fn facts, ctx, {mod, fun, arity} = mfa ->
      @by_mod_fun
      |> Map.get({mod, fun}, [])
      |> Enum.concat(Map.get(@by_mod_fun, {mod, :any}, []))
      |> Enum.filter(fn {{_m, _f, a}, _rel, _cols} -> arity_matches?(a, arity) end)
      |> Enum.reduce(facts, fn {_mfa, relation, columns}, acc ->
        emit(acc, ctx, mfa, relation, columns)
      end)
    end)
  end

  defp arity_matches?(:any, _arity), do: true
  defp arity_matches?(arities, arity) when is_list(arities), do: arity in arities
  defp arity_matches?(a, arity), do: a == arity

  # Reads every column. A guard reader adds nothing and may veto the row
  # (`:skip`); a value reader may record an imprecision against the
  # relation being emitted.
  defp emit(facts, ctx, mfa, relation, columns) do
    Enum.reduce_while(columns, {facts, []}, fn column, {acc, row} ->
      case read(column, ctx, mfa, acc, relation) do
        {:skip, acc} -> {:halt, {acc, :skip}}
        {:pass, acc} -> {:cont, {acc, row}}
        {value, acc} -> {:cont, {acc, [value | row]}}
      end
    end)
    |> case do
      {acc, :skip} -> acc
      {acc, row} -> add_fact(acc, relation, Enum.reverse(row))
    end
  end

  # ── Readers ────────────────────────────────────────────────────────────

  defp read(:id, ctx, _mfa, facts, _rel), do: {InstrId.mint(ctx.func_id, ctx.idx), facts}
  defp read(:func, ctx, _mfa, facts, _rel), do: {ctx.func_id, facts}
  defp read(:mod, _ctx, {m, _f, _a}, facts, _rel), do: {inspect(m), facts}
  defp read(:fun, _ctx, {_m, f, _a}, facts, _rel), do: {to_string(f), facts}
  defp read(:arity, _ctx, {_m, _f, a}, facts, _rel), do: {to_string(a), facts}
  defp read(:api, _ctx, {m, f, a}, facts, _rel), do: {"#{inspect(m)}.#{f}/#{a}", facts}
  defp read(:mod_fun, _ctx, {m, f, _a}, facts, _rel), do: {"#{inspect(m)}.#{f}", facts}
  defp read({:const, value}, _ctx, _mfa, facts, _rel), do: {value, facts}

  defp read({:module_target, n}, ctx, _mfa, facts, rel) do
    case module_target(ctx.instrs, ctx.idx, {:x, n}) do
      "dynamic" -> {"dynamic", track_imprecision(facts, ctx, :genserver_callee, rel)}
      target -> {target, facts}
    end
  end

  defp read({:supervisor_target, n}, ctx, _mfa, facts, rel) do
    case module_target(ctx.instrs, ctx.idx, {:x, n}) do
      "dynamic" -> {"dynamic", track_imprecision(facts, ctx, :supervisor_target, rel)}
      target -> {target, facts}
    end
  end

  defp read({:atom, n, category}, ctx, _mfa, facts, rel) do
    value = resolve_atom(ctx.instrs, ctx.idx, {:x, n})
    {value, track_dynamic(facts, value, ctx, category, rel)}
  end

  defp read({:timeout, n, category}, ctx, _mfa, facts, rel) do
    case timeout_ms(ctx.instrs, ctx.idx, {:x, n}) do
      "0" -> {"0", track_imprecision(facts, ctx, category, rel)}
      value -> {value, facts}
    end
  end

  defp read({:retries, n}, ctx, _mfa, facts, rel) do
    value =
      case resolve_register(ctx.instrs, ctx.idx, {:x, n}) do
        {:ok, 0} -> "0"
        {:ok, k} when is_integer(k) and k > 0 -> to_string(k)
        {:ok, :infinity} -> "infinity"
        _ -> "dynamic"
      end

    {value, track_dynamic(facts, value, ctx, :global_op_retries, rel)}
  end

  defp read({:deserialization_safety, n}, ctx, _mfa, facts, rel) do
    value =
      case resolve_register(ctx.instrs, ctx.idx, {:x, n}) do
        {:ok, opts} when is_list(opts) -> if :safe in opts, do: "atoms_only", else: "unsafe"
        _ -> "dynamic"
      end

    {value, track_dynamic(facts, value, ctx, :unsafe_deserialization_safety, rel)}
  end

  # Port.open's name is a `{mechanism, spec}` tuple; the spec (the command,
  # the executable path, the driver name) is the interesting part.
  defp read({:port_target, n}, ctx, _mfa, facts, rel) do
    value =
      case resolve_register(ctx.instrs, ctx.idx, {:x, n}) do
        {:ok, {kind, spec}} when kind in [:spawn, :spawn_executable, :spawn_driver] ->
          display(spec)

        {:ok, {:fd, _in, _out}} ->
          "fd"

        {:ok, other} ->
          display(other)

        _ ->
          "dynamic"
      end

    {value, track_dynamic(facts, value, ctx, :port_target, rel)}
  end

  defp read({:command, n}, ctx, _mfa, facts, rel) do
    value =
      case resolve_register(ctx.instrs, ctx.idx, {:x, n}) do
        {:ok, value} -> display(value)
        _ -> "dynamic"
      end

    {value, track_dynamic(facts, value, ctx, :port_target, rel)}
  end

  @interpreters ~w(sh bash zsh dash ksh csh tcsh fish cmd cmd.exe powershell pwsh
                   python python3 perl ruby node erl elixir iex escript osascript)

  # A literal command runs only itself: its arguments are argv, never
  # parsed by a shell, so caller data in them is not code execution. The
  # exception is a literal shell or interpreter, which executes whatever
  # its arguments say — that stays a finding unless the arguments are
  # literal too. The empty argument list arrives as the atom `nil`.
  defp read(:unless_static_command, ctx, _mfa, facts, _rel) do
    command = resolve_register(ctx.instrs, ctx.idx, {:x, 0})
    args = resolve_register(ctx.instrs, ctx.idx, {:x, 1})
    static_args? = match?({:ok, a} when is_list(a) or is_nil(a), args)

    case command do
      {:ok, c} when is_binary(c) ->
        if Path.basename(c) in @interpreters and not static_args?,
          do: {:pass, facts},
          else: {:skip, facts}

      _ ->
        {:pass, facts}
    end
  end

  defp display(:dynamic), do: "dynamic"
  defp display(value) when is_binary(value), do: cap(value)

  defp display(value) when is_list(value),
    do: if(List.ascii_printable?(value), do: cap(List.to_string(value)), else: "dynamic")

  defp display(value) when is_atom(value), do: inspect(value)
  defp display(_value), do: "dynamic"

  defp cap(string) when byte_size(string) > 80, do: binary_part(string, 0, 79) <> "…"
  defp cap(string), do: string
end
