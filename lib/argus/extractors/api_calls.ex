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
    calls (GenServer, gen_statem, GenStage, Agent, gen_event, supervisors);
    `sync_call_site` — each synchronous call's target and timeout, by site
  - `unsafe_atom_creation`, `unsafe_deserialization`, `code_execution`
  - `port_open`
  - `rpc_call`, `rpc_target`, `rpc_timeout_param`, `rpc_arity`, `global_register`, `global_op`,
    `node_operation`,
    `distributed_store_op`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [each_remote_call: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 4]

  import Argus.Extractor.Resolve,
    only: [
      arg_position: 3,
      module_target: 3,
      node_list: 3,
      resolve_atom: 3,
      resolve_register: 3,
      timeout_ms: 3
    ]

  # ── The table ──────────────────────────────────────────────────────────

  # Synchronous calls: {mfa, the argument naming the server, the
  # timeout}. The timeout is the documented default when the call has
  # none, or the argument that holds it — the signatures' positions:
  # `multi_call(nodes, name, request, timeout)` names its server second.
  @sync_calls [
    {{GenServer, :call, 2}, 0, {:const, "5000"}},
    {{:gen_server, :call, 2}, 0, {:const, "5000"}},
    {{GenStage, :call, 2}, 0, {:const, "5000"}},
    {{Agent, :get, 2}, 0, {:const, "5000"}},
    {{Agent, :update, 2}, 0, {:const, "5000"}},
    {{Agent, :get_and_update, 2}, 0, {:const, "5000"}},
    {{Agent, :get, 4}, 0, {:const, "5000"}},
    {{Agent, :update, 4}, 0, {:const, "5000"}},
    {{Agent, :get_and_update, 4}, 0, {:const, "5000"}},
    # A gen_statem client that omits the timeout waits forever.
    {{:gen_statem, :call, 2}, 0, {:const, "-1"}},
    {{GenStateMachine, :call, 2}, 0, {:const, "-1"}},
    {{GenServer, :multi_call, 2}, 0, {:const, "-1"}},
    {{GenServer, :multi_call, 3}, 1, {:const, "-1"}},
    {{GenServer, :multi_call, 4}, 1, {:timeout, 3}},
    {{:gen_server, :multi_call, 2}, 0, {:const, "-1"}},
    {{:gen_server, :multi_call, 3}, 1, {:const, "-1"}},
    {{:gen_server, :multi_call, 4}, 1, {:timeout, 3}},
    {{GenServer, :call, 3}, 0, {:timeout, 2}},
    {{:gen_server, :call, 3}, 0, {:timeout, 2}},
    {{:gen_statem, :call, 3}, 0, {:timeout, 2}},
    {{GenStateMachine, :call, 3}, 0, {:timeout, 2}},
    {{GenStage, :call, 3}, 0, {:timeout, 2}},
    {{Agent, :get, 3}, 0, {:timeout, 2}},
    {{Agent, :update, 3}, 0, {:timeout, 2}},
    {{Agent, :get_and_update, 3}, 0, {:timeout, 2}},
    {{Agent, :get, 5}, 0, {:timeout, 4}},
    {{Agent, :update, 5}, 0, {:timeout, 4}},
    {{Agent, :get_and_update, 5}, 0, {:timeout, 4}}
  ]

  @sync_mfas Enum.map(@sync_calls, &elem(&1, 0))

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
    {GenServer, :stop, [1, 2, 3]},
    {:gen_server, :stop, [1, 2, 3]},
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

  # Remote calls that wait for an answer: {mfa, variant, timeout,
  # target}. The timeout is "-1" where the arity leaves it out and the
  # default is :infinity, or the argument that holds it; the target is
  # the remote function, read from the M and F arguments, "fun" for the
  # forms that take a fun, and "dynamic" where the site does not name it
  # (a yield or receive_response collects what an earlier request asked).
  #
  # rpc:multicall(M, F, A) and multicall(Nodes, M, F, A) wait forever;
  # multicall(M, F, A, Timeout) is the other /4, told apart by what its
  # third argument holds. erpc's default timeout is infinity too:
  # call(Node, Fun), call(Node, M, F, A), and multicall likewise with
  # Nodes. block_call is call without the rex server's parallelism,
  # yield(Key) and receive_response(ReqId) wait for an answer an earlier
  # async_call or send_request asked for, forever unless given a timeout;
  # nb_yield(Key) and wait_response(ReqId) do not wait, and are not here.
  @rpc_calls [
    {{:rpc, :call, 4}, "rpc", {:const, "-1"}, {:target, 1, 2}},
    {{:rpc, :call, 5}, "rpc", {:timeout, 4, :rpc_timeout}, {:target, 1, 2}},
    {{:rpc, :block_call, 4}, "block_call", {:const, "-1"}, {:target, 1, 2}},
    {{:rpc, :block_call, 5}, "block_call", {:timeout, 4, :rpc_timeout}, {:target, 1, 2}},
    {{:rpc, :multicall, 3}, "multicall", {:const, "-1"}, {:target, 0, 1}},
    {{:rpc, :multicall, 4}, "multicall", {:multicall_timeout, 3, :rpc_timeout},
     :multicall_target},
    {{:rpc, :multicall, 5}, "multicall", {:timeout, 4, :rpc_timeout}, {:target, 1, 2}},
    {{:rpc, :yield, 1}, "yield", {:const, "-1"}, {:const, "dynamic"}},
    {{:rpc, :nb_yield, 2}, "nb_yield", {:timeout, 1, :rpc_timeout}, {:const, "dynamic"}},
    {{:erpc, :call, 2}, "erpc", {:const, "-1"}, {:const, "fun"}},
    {{:erpc, :call, 3}, "erpc", {:timeout, 2, :rpc_timeout}, {:const, "fun"}},
    {{:erpc, :call, 4}, "erpc", {:const, "-1"}, {:target, 1, 2}},
    {{:erpc, :call, 5}, "erpc", {:timeout, 4, :rpc_timeout}, {:target, 1, 2}},
    {{:erpc, :multicall, 2}, "erpc_multicall", {:const, "-1"}, {:const, "fun"}},
    {{:erpc, :multicall, 3}, "erpc_multicall", {:timeout, 2, :rpc_timeout}, {:const, "fun"}},
    {{:erpc, :multicall, 4}, "erpc_multicall", {:const, "-1"}, {:target, 1, 2}},
    {{:erpc, :multicall, 5}, "erpc_multicall", {:timeout, 4, :rpc_timeout}, {:target, 1, 2}},
    {{:erpc, :receive_response, 1}, "erpc_receive", {:const, "-1"}, {:const, "dynamic"}},
    {{:erpc, :receive_response, [2, 3]}, "erpc_receive", {:timeout, 1, :rpc_timeout},
     {:const, "dynamic"}}
  ]

  # A synchronous call's site row repeats what sync_call and
  # sync_call_timeout say about the function, for the rules that must pair
  # a call's target with its own timeout; its readers record no
  # imprecision a second time.
  @table ((for {mfa, target, timeout} <- @sync_calls do
             column =
               case timeout do
                 {:timeout, n} -> {:timeout, n, :sync_call_timeout}
                 const -> const
               end

             site_column =
               if match?({:timeout, _}, timeout), do: {:untracked, column}, else: column

             [
               {mfa, :sync_call, [:func, {:module_target, target}]},
               {mfa, :sync_call_timeout, [:func, {:module_target, target}, column]},
               {mfa, :sync_call_site,
                [:id, :func, {:untracked, {:module_target, target}}, site_column]}
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
           {{:global, :register_name, [2, 3]}, :global_register,
            [:id, :func, {:atom, 0, :global_register_name}, :arity]},
           # A lock call that leaves out its node list takes the lock on
           # every known node — `[node() | nodes()]` — so the omitted
           # argument is "cluster".
           {{:global, :set_lock, 1}, :global_op,
            [:id, :func, {:const, "set_lock"}, {:const, "infinity"}, {:const, "cluster"}]},
           {{:global, :set_lock, 2}, :global_op,
            [:id, :func, {:const, "set_lock"}, {:const, "infinity"}, {:nodes, 1}]},
           {{:global, :set_lock, 3}, :global_op,
            [:id, :func, {:const, "set_lock"}, {:retries, 2}, {:nodes, 1}]},
           {{:global, :del_lock, 1}, :global_op,
            [:id, :func, {:const, "del_lock"}, {:const, "0"}, {:const, "cluster"}]},
           {{:global, :del_lock, 2}, :global_op,
            [:id, :func, {:const, "del_lock"}, {:const, "0"}, {:nodes, 1}]},
           {{:global, :trans, 2}, :global_op,
            [:id, :func, {:const, "trans"}, {:const, "infinity"}, {:const, "cluster"}]},
           {{:global, :trans, 3}, :global_op,
            [:id, :func, {:const, "trans"}, {:const, "infinity"}, {:nodes, 2}]},
           {{:global, :trans, 4}, :global_op,
            [:id, :func, {:const, "trans"}, {:retries, 3}, {:nodes, 2}]},
           # A name lookup and a send take no node list.
           {{:global, :whereis_name, 1}, :global_op,
            [:id, :func, {:const, "whereis_name"}, {:const, "0"}, {:const, ""}]},
           {{:global, :send, 2}, :global_op,
            [:id, :func, {:const, "send"}, {:const, "0"}, {:const, ""}]}
         ])
         |> Kernel.++(
           for {mfa, variant, timeout, target} <- @rpc_calls,
               row <- [
                 {mfa, :rpc_call, [:id, :func, {:const, variant}, timeout]},
                 {mfa, :rpc_target, [:id, target]},
                 {mfa, :rpc_timeout_param, [:id, {:timeout_param, timeout}]},
                 {mfa, :rpc_arity, [:id, {:arity_of, target}]}
               ],
               do: row
         )
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

  @sink_relations [:unsafe_atom_creation, :unsafe_deserialization, :code_execution]
  @sink_mfas @table
             |> Enum.filter(fn {_mfa, rel, _cols} -> rel in @sink_relations end)
             |> Enum.map(fn {mfa, _rel, _cols} -> mfa end)
             |> Enum.uniq()

  @doc """
  The calls `unsafe_input` treats as sinks — atom creation, deserialization
  and code execution — as the table spells them: `{mod, fun, arity}` where
  `arity` may be a list or `:any`. One table, so a dataflow extractor and
  the sink extractor cannot disagree about what a sink is.
  """
  @spec sink_mfas() :: [{module(), atom(), arity() | [arity()] | :any}]
  def sink_mfas, do: @sink_mfas

  @doc """
  Whether a concrete `{mod, fun, arity}` is a synchronous call (`:call`) or
  an asynchronous cast (`:cast`) to the process its first argument names,
  from the same table `sync_call` and `async_cast` come from; `nil`
  otherwise. `multi_call` is left out: its first argument is nodes.
  """
  @spec process_call_kind({module(), atom(), arity()}) :: :call | :cast | nil
  def process_call_kind({_mod, :multi_call, _arity}), do: nil

  def process_call_kind(mfa) do
    cond do
      listed?(mfa, @sync_mfas) ->
        :call

      listed?(mfa, @async) ->
        :cast

      true ->
        nil
    end
  end

  defp listed?({mod, fun, arity}, table) do
    Enum.any?(table, fn {m, f, a} -> m == mod and f == fun and arity_matches?(a, arity) end)
  end

  @doc "Whether a concrete `{mod, fun, arity}` is one of `sink_mfas/0`."
  @spec sink?({module(), atom(), arity()}) :: boolean()
  def sink?({mod, fun, arity}) do
    Enum.any?(@sink_mfas, fn
      {^mod, ^fun, :any} -> true
      {^mod, ^fun, arities} when is_list(arities) -> arity in arities
      {^mod, ^fun, ^arity} -> true
      _ -> false
    end)
  end

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
      :rpc_arity,
      :rpc_call,
      :rpc_target,
      :rpc_timeout_param,
      :sup_call,
      :sync_call,
      :sync_call_site,
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

  defp read({:untracked, reader}, ctx, mfa, facts, rel) do
    {value, _tracked} = read(reader, ctx, mfa, facts, rel)
    {value, facts}
  end

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

  # rpc:multicall/4 is multicall(Nodes, M, F, A), which waits forever,
  # or multicall(M, F, A, Timeout): the third argument is a function name
  # in the first and an argument list in the second.
  defp read({:multicall_timeout, n, category}, ctx, mfa, facts, rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, n - 1}) do
      {:ok, fun} when is_atom(fun) and fun != :dynamic -> {"-1", facts}
      _ -> read({:timeout, n, category}, ctx, mfa, facts, rel)
    end
  end

  # The remote function a call names, "Mod.fun" as the M and F
  # arguments spell it, or "dynamic" when either is not a literal atom.
  defp read({:target, m, f}, ctx, _mfa, facts, _rel) do
    with {:ok, mod} when is_atom(mod) and mod != :dynamic <-
           resolve_register(ctx.instrs, ctx.idx, {:x, m}),
         {:ok, fun} when is_atom(fun) and fun != :dynamic <-
           resolve_register(ctx.instrs, ctx.idx, {:x, f}) do
      {"#{inspect(mod)}.#{fun}", facts}
    else
      _ -> {"dynamic", facts}
    end
  end

  # multicall(Nodes, M, F, A) names its function third, multicall(M, F,
  # A, Timeout) second: told apart as {:multicall_timeout, 3, _} does.
  defp read(:multicall_target, ctx, mfa, facts, rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 2}) do
      {:ok, fun} when is_atom(fun) and fun != :dynamic ->
        read({:target, 1, 2}, ctx, mfa, facts, rel)

      _ ->
        read({:target, 0, 1}, ctx, mfa, facts, rel)
    end
  end

  # How many arguments the remote function gets: the length of the list
  # after F, when every path builds it whole. A `:dynamic` element may be
  # an unknown value or an unknown tail, so a list holding one has no
  # length here. The forms that take a fun or name no target have none.
  defp read({:arity_of, {:target, _m, f}}, ctx, _mfa, facts, _rel),
    do: {arg_count(ctx, f + 1), facts}

  defp read({:arity_of, :multicall_target}, ctx, _mfa, facts, _rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 2}) do
      {:ok, fun} when is_atom(fun) and fun != :dynamic -> {arg_count(ctx, 3), facts}
      _ -> {arg_count(ctx, 2), facts}
    end
  end

  defp read({:arity_of, {:const, _}}, _ctx, _mfa, facts, _rel), do: {:skip, facts}

  # Which of the function's parameters a timeout argument is, when it is
  # one on every path (a wrapper's `timeout \\ :infinity`): the rules
  # ask whether a caller passes :infinity there. Any other timeout —
  # a literal, the default, something computed — adds no row.
  defp read({:timeout_param, {:timeout, n, _category}}, ctx, _mfa, facts, _rel) do
    case arg_position(ctx.instrs, ctx.idx, {:x, n}) do
      {:ok, k} -> {to_string(k), facts}
      :no -> {:skip, facts}
    end
  end

  defp read({:timeout_param, {:multicall_timeout, n, _category}}, ctx, mfa, facts, rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, n - 1}) do
      {:ok, fun} when is_atom(fun) and fun != :dynamic -> {:skip, facts}
      _ -> read({:timeout_param, {:timeout, n, :rpc_timeout}}, ctx, mfa, facts, rel)
    end
  end

  defp read({:timeout_param, {:const, _}}, _ctx, _mfa, facts, _rel), do: {:skip, facts}

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

  defp read({:nodes, n}, ctx, _mfa, facts, rel) do
    case node_list(ctx.instrs, ctx.idx, {:x, n}) do
      "unknown" -> {"unknown", track_imprecision(facts, ctx, :global_op_nodes, rel)}
      nodes -> {nodes, facts}
    end
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

  defp arg_count(ctx, n) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, n}) do
      {:ok, nil} -> "0"
      {:ok, args} when is_list(args) -> if :dynamic in args, do: :skip, else: "#{length(args)}"
      _ -> :skip
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
