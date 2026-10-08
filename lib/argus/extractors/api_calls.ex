defmodule Argus.Extractors.ApiCalls do
  @moduledoc """
  Calls to known APIs, classified by a table.

  Each table entry is `{{mod, fun, arity}, relation, columns}`. `arity`
  accepts an integer, a list, or `:any`; `fun: :any` matches every function
  in a module. The table also defines the sink APIs shared with dataflow
  extractors and the relations this extractor declares.

  Columns are readers (see `read/4`): `:id`, `:func`, `:api`, `:fun`,
  `:arity`, `{:const, value}`, `{:module_target, n}`, `{:atom, n,
  category}`, `{:timeout, n, category}`, and a few domain readers. A
  reader that resolves to `"dynamic"` records the imprecision under its
  category when coverage tracing is enabled.

  ## Emitted facts

  - `sync_call`, `sync_call_timeout`, `async_cast`, `sup_call` — process
    calls (GenServer, gen_statem, GenStage, Agent, gen_event, supervisors);
    `sync_call_site` — each synchronous call's target and timeout, by site;
    `async_cast_site` — each cast's target, by site
  - `unsafe_atom_creation`, `unsafe_deserialization`, `unsafe_decompression`,
    `code_execution`
  - `port_open`
  - `rpc_call`, `rpc_target`, `rpc_timeout_param`, `rpc_arity`, `rpc_callee`,
    `rpc_mfa_param`, `global_register`, `global_op`,
    `node_operation`,
    `distributed_store_op`
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Argv
  alias Argus.Extractor.Resolve
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [each_remote_call: 3]
  import Argus.Instr, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 4]

  import Argus.Extractor.Resolve,
    only: [
      arg_position: 3,
      call_result_origin: 3,
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

  # Elixir compiles Node.spawn/2..5 and Node.spawn_link/2,4 to the
  # :erlang spawns that take a node, and Node.list/0,1 to :erlang.nodes,
  # which asks no other node. A spawn on another node waits for that
  # node's reply, with no timeout.
  @node_ops [
    {Node, :connect, 1},
    {Node, :disconnect, 1},
    {:erlang, :spawn, [2, 4]},
    {:erlang, :spawn_link, [2, 4]},
    {:erlang, :spawn_monitor, [2, 4]},
    {:erlang, :spawn_opt, [3, 5]},
    {Node, :ping, 1},
    {Node, :monitor, 2},
    {:net_kernel, :connect_node, 1},
    {:net_kernel, :monitor_nodes, [1, 2]}
  ]

  # The distributed store is Mnesia alone: a DETS table is a file on the
  # node that opened it, so nothing a DETS call waits on is a peer.
  @mnesia_ops ~w(read write delete delete_object first next last prev match_object select
                 index_read dirty_read dirty_write dirty_delete dirty_first dirty_next
                 dirty_last dirty_match_object dirty_index_read transaction activity
                 sync_transaction async_dirty sync_dirty create_table delete_table
                 add_table_index add_table_copy change_table_copy_type)a

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
  # a call's target with its own timeout, and a cast's repeats async_cast
  # for the rules that must pair a cast's target with its own tag; their
  # readers record no imprecision a second time.
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
            for(
              mfa <- @async,
              do: [
                {mfa, :async_cast, [:func, {:module_target, 0}]},
                {mfa, :async_cast_site, [:id, :func, {:untracked, {:module_target, 0}}]}
              ]
            ))
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
           # One-shot decompression: the whole output of an input with no
           # bound on its size. The column is the compressed data's position
           # (`inflate(Z, Data)` takes it second). The streaming forms that
           # hand back a bounded chunk (`safeInflate/2`, `inflateChunk/1,2`)
           # are the fix and no sink.
           {{:zlib, :gunzip, 1}, :unsafe_decompression, [:id, :func, :api, {:const, "0"}]},
           {{:zlib, :unzip, 1}, :unsafe_decompression, [:id, :func, :api, {:const, "0"}]},
           {{:zlib, :uncompress, 1}, :unsafe_decompression, [:id, :func, :api, {:const, "0"}]},
           {{:zlib, :inflate, [2, 3]}, :unsafe_decompression, [:id, :func, :api, {:const, "1"}]},
           {{Code, :eval_string, [1, 2, 3]}, :code_execution, [:id, :func, :api]},
           {{Code, :compile_string, [1, 2]}, :code_execution, [:id, :func, :api]},
           {{EEx, :eval_string, [1, 2, 3]}, :code_execution,
            [:id, :func, :api, :unless_literal_source]},
           {{EEx, :compile_string, [1, 2]}, :code_execution,
            [:id, :func, :api, :unless_literal_source]},
           {{:os, :cmd, [1, 2]}, :code_execution, [:id, :func, :api, :unless_literal_command]},
           {{System, :shell, [1, 2]}, :code_execution,
            [:id, :func, :api, :unless_literal_command]},
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
                 {mfa, :rpc_arity, [:id, {:arity_of, target}]},
                 {mfa, :rpc_callee, [:id, :func, {:callee_mod, target}, {:callee, target}]}
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

  # Indexed by {mod, fun} at compile time; arity is checked per entry.
  @by_mod_fun Enum.group_by(@table, fn {{m, f, _a}, _rel, _cols} -> {m, f} end)

  # rpc_mfa_param is emitted separately because it follows closure captures.
  @relations [:rpc_mfa_param | Enum.map(@table, &elem(&1, 1))] |> Enum.uniq() |> Enum.sort()

  @sink_relations [
    :unsafe_atom_creation,
    :unsafe_deserialization,
    :unsafe_decompression,
    :code_execution
  ]
  @sink_mfas @table
             |> Enum.filter(fn {_mfa, rel, _cols} -> rel in @sink_relations end)
             |> Enum.map(fn {mfa, _rel, _cols} -> mfa end)
             |> Enum.uniq()

  @doc """
  APIs treated as unsafe-input sinks: atom creation, deserialization,
  one-shot decompression and code execution. Entries are `{mod, fun, arity}`;
  `arity` may be an integer, a list, or `:any`.
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

  defp listed?(mfa, table), do: Enum.any?(table, &mfa_matches?(&1, mfa))

  @doc "Whether a concrete `{mod, fun, arity}` is one of `sink_mfas/0`."
  @spec sink?({module(), atom(), arity()}) :: boolean()
  def sink?(mfa), do: listed?(mfa, @sink_mfas)

  @atom_sink_mfas @table
                  |> Enum.filter(fn {_mfa, rel, _cols} -> rel == :unsafe_atom_creation end)
                  |> Enum.map(fn {mfa, _rel, _cols} -> mfa end)
                  |> Enum.uniq()

  @doc """
  Whether a concrete `{mod, fun, arity}` creates atoms. Its risk depends
  on the number of possible argument values, rather than their contents.
  """
  @spec atom_sink?({module(), atom(), arity()}) :: boolean()
  def atom_sink?(mfa), do: listed?(mfa, @atom_sink_mfas)

  defp mfa_matches?({mod, fun, :any}, {mod, fun, _arity}), do: true

  defp mfa_matches?({mod, fun, arities}, {mod, fun, arity}) when is_list(arities),
    do: arity in arities

  defp mfa_matches?({mod, fun, arity}, {mod, fun, arity}), do: true
  defp mfa_matches?(_entry, _mfa), do: false

  @impl true
  def relations, do: @relations

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    origins =
      Map.get_lazy(module_data, :capture_origins, fn ->
        {:parents, closure_parents(module_data)}
      end)

    each_remote_call(module_data, %{}, fn facts, ctx, {mod, fun, arity} = mfa ->
      @by_mod_fun
      |> Map.get({mod, fun}, [])
      |> Enum.concat(Map.get(@by_mod_fun, {mod, :any}, []))
      |> Enum.filter(fn {{_m, _f, a}, _rel, _cols} -> arity_matches?(a, arity) end)
      |> Enum.reduce(facts, fn {_mfa, relation, columns}, acc ->
        emit(acc, ctx, mfa, relation, columns)
      end)
      |> rpc_mfa_param(ctx, mfa, origins)
    end)
  end

  # ── An rpc's module, function and arguments, handed in ─────────────────
  #
  # A wrapper around an rpc (`Rpc.call(node, mod, fun, args, opts)`) runs
  # whatever its callers hand it: its rpc names no target, but the three
  # are its parameters, and each caller's literals say what runs
  # (`mfa_arg`, clientlib/rpc_targets.dl). In a closure the wrapper builds
  # (`:timer.tc(fn -> :erpc.call(node, mod, fun, args) end)`), the three
  # are captured variables: followed to the parameters of the function
  # that built it, within the module.

  # The rpc forms whose target is three registers in a row: M, F, A.
  @rpc_mfa_regs %{
    {:rpc, :call, 4} => 1,
    {:rpc, :call, 5} => 1,
    {:rpc, :block_call, 4} => 1,
    {:rpc, :block_call, 5} => 1,
    {:rpc, :multicall, 5} => 1,
    {:erpc, :call, 4} => 1,
    {:erpc, :call, 5} => 1,
    {:erpc, :multicall, 4} => 1,
    {:erpc, :multicall, 5} => 1
  }

  defp rpc_mfa_param(facts, ctx, mfa, origins) do
    with {:ok, m} <- Map.fetch(@rpc_mfa_regs, mfa),
         {:ok, {holder, k}} <- parameter_origin(ctx, {:x, m}, origins),
         {:ok, {^holder, k1}} <-
           parameter_origin(ctx, {:x, m + 1}, origins),
         {:ok, {^holder, k2}} <-
           parameter_origin(ctx, {:x, m + 2}, origins),
         true <- k1 == k + 1 and k2 == k + 2 do
      add_fact(facts, :rpc_mfa_param, [
        InstrId.mint(ctx.func_id, ctx.idx),
        holder,
        to_string(k)
      ])
    else
      _ -> facts
    end
  end

  defp parameter_origin(ctx, reg, {:parents, parents}),
    do: holder_param(ctx.func_id, ctx.instrs, ctx.idx, reg, parents)

  defp parameter_origin(ctx, reg, origins) do
    with {:ok, k} <- Resolve.arg_position(ctx.instrs, ctx.idx, reg) do
      case Map.fetch(origins, ctx.func_id) do
        {:ok, {first, captures}} when k >= first -> Map.get(captures, k, :no)
        _ -> {:ok, {ctx.func_id, k}}
      end
    end
  end

  @doc "Captured parameter origins, preserving ambiguous or unresolved captures."
  @spec capture_origins(Argus.Extractor.module_data()) :: map()
  def capture_origins(module_data) do
    parents = closure_parents(module_data)

    Map.new(parents, fn {closure, {parent, instrs, at, first, env}} ->
      captures =
        env
        |> Enum.with_index(first)
        |> Map.new(fn {operand, k} ->
          origin =
            case register(operand) do
              {kind, _} = captured when kind in [:x, :y] ->
                holder_param(parent, instrs, at, captured, parents)

              _ ->
                :no
            end

          {k, origin}
        end)

      {closure, {first, captures}}
    end)
  end

  # Which parameter of which function the value in `reg` at `idx` is, on
  # every path: `func`'s own, or — `func` being a closure — the variable
  # its parent captured there, followed to the parent's parameter.
  defp holder_param(func, instrs, idx, reg, parents, seen \\ %{}) do
    key = {func, idx, reg}

    if Map.has_key?(seen, key) do
      :no
    else
      follow_holder(func, instrs, idx, reg, parents, Map.put(seen, key, true))
    end
  end

  defp follow_holder(func, instrs, idx, reg, parents, seen) do
    with {:ok, k} <- Resolve.arg_position(instrs, idx, reg) do
      case Map.fetch(parents, func) do
        {:ok, {parent, parent_instrs, at, first, env}} when k >= first ->
          case register(Enum.at(env, k - first)) do
            {kind, _} = captured when kind in [:x, :y] ->
              holder_param(parent, parent_instrs, at, captured, parents, seen)

            _literal ->
              :no
          end

        _ ->
          {:ok, {func, k}}
      end
    end
  end

  # Every closure the module builds with a concrete MFA, and where: its
  # parent, the parent's instructions, the make_fun3's index, the first
  # parameter the environment fills and the environment's operands. A
  # closure built in two places has no one parent, and is left out.
  defp closure_parents(%{module: mod, functions: functions}) do
    functions
    |> Enum.flat_map(fn {:function, name, arity, _entry, instrs} ->
      parent = InstrId.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}, at} ->
          closure = InstrId.func_id(cmod, cname, carity)
          [{closure, {parent, instrs, at, carity - length(env), env}}]

        _ ->
          []
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {closure, [site]} -> [{closure, site}]
      _built_twice -> []
    end)
    |> Map.new()
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

  # ── Commands ───────────────────────────────────────────────────────────

  # The programs that run what their arguments say: shells and
  # interpreters, and the wrappers that run another program named in
  # their arguments (`env cmd`, `sudo cmd`, `xargs cmd`, `timeout 5 cmd`),
  # hand a command to a remote shell (`ssh host cmd`), or run one in a
  # container (`docker exec c cmd`). A literal program not listed runs
  # only itself; one of these runs its caller's data.
  @interpreters ~w(sh bash zsh dash ksh csh tcsh fish ash busybox cmd cmd.exe powershell pwsh
                   python python2 python3 perl ruby node deno bun erl elixir iex escript mix
                   php lua luajit tclsh wish Rscript julia awk gawk mawk nawk osascript
                   env sudo doas su runuser xargs nohup nice ionice timeout stdbuf time watch
                   flock setsid chroot nsenter unshare strace ltrace
                   ssh docker podman kubectl nerdctl lxc-attach)

  @doc """
  Whether the `System.cmd/2,3` call at `ctx` runs a program its
  arguments cannot turn into code: a literal program that is no shell or
  interpreter, or one handed arguments that are literal on every path
  `scope` shows (`Argus.Extractor.Argv`). `key` is the function in
  `scope` that holds the call. A program that is not literal is never
  fixed.
  """
  @spec fixed_command?(
          Argus.Extractor.Helpers.instr_ctx(),
          Argv.scope(),
          Argv.key()
        ) :: boolean()
  def fixed_command?(ctx, scope, key) do
    case static_command(ctx) do
      {:ok, command} ->
        Path.basename(command) not in @interpreters or
          Argv.literal?(scope, key, ctx.idx, {:x, 1})

      :dynamic ->
        false
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
  defp read(:fun, _ctx, {_m, f, _a}, facts, _rel), do: {InstrId.name(f), facts}
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
  # or multicall(M, F, A, Timeout) (`multicall_form/1`). A form the
  # arguments do not tell waits as long as the fourth says, if it is the
  # timeout: unknown.
  defp read({:multicall_timeout, n, category}, ctx, mfa, facts, rel) do
    case multicall_form(ctx) do
      :nodes -> {"-1", facts}
      _timeout_or_unknown -> read({:timeout, n, category}, ctx, mfa, facts, rel)
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
  # A, Timeout) second (`multicall_form/1`).
  defp read(:multicall_target, ctx, mfa, facts, rel) do
    case multicall_form(ctx) do
      :nodes -> read({:target, 1, 2}, ctx, mfa, facts, rel)
      :timeout -> read({:target, 0, 1}, ctx, mfa, facts, rel)
      :unknown -> {"dynamic", facts}
    end
  end

  # How many arguments the remote function gets: the length of the list
  # after F, when every path builds it whole. A `:dynamic` element may be
  # an unknown value or an unknown tail, so a list holding one has no
  # length here. The forms that take a fun or name no target have none.
  defp read({:arity_of, {:target, _m, f}}, ctx, _mfa, facts, _rel),
    do: {arg_count(ctx, f + 1), facts}

  defp read({:arity_of, :multicall_target}, ctx, _mfa, facts, _rel) do
    case multicall_form(ctx) do
      :nodes -> {arg_count(ctx, 3), facts}
      :timeout -> {arg_count(ctx, 2), facts}
      :unknown -> {:skip, facts}
    end
  end

  defp read({:arity_of, {:const, _}}, _ctx, _mfa, facts, _rel), do: {:skip, facts}

  # The function an rpc runs, as a function ID, when its module and name
  # are literal atoms and its argument list's length is known on every
  # path (cons cells counted, their values not needed); the row is
  # skipped otherwise. The forms that take a fun, or whose function is
  # chosen at runtime (multicall's two shapes), name none.
  defp read({:callee_mod, {:target, m, f}}, ctx, _mfa, facts, _rel) do
    case rpc_callee(ctx, m, f) do
      nil -> {:skip, facts}
      {mod, _callee} -> {mod, facts}
    end
  end

  defp read({:callee_mod, _target}, _ctx, _mfa, facts, _rel), do: {:skip, facts}

  defp read({:callee, {:target, m, f}}, ctx, _mfa, facts, _rel) do
    case rpc_callee(ctx, m, f) do
      nil -> {:skip, facts}
      {_mod, callee} -> {callee, facts}
    end
  end

  defp read({:callee, _target}, _ctx, _mfa, facts, _rel), do: {:skip, facts}

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

  # Only a fourth argument known to be the timeout is a timeout parameter:
  # in the other form it is the argument list.
  defp read({:timeout_param, {:multicall_timeout, n, _category}}, ctx, mfa, facts, rel) do
    case multicall_form(ctx) do
      :timeout -> read({:timeout_param, {:timeout, n, :rpc_timeout}}, ctx, mfa, facts, rel)
      _nodes_or_unknown -> {:skip, facts}
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

  # A literal command runs only itself: its arguments are argv, never
  # parsed by a shell, so caller data in them is not code execution. The
  # exception is a literal shell or interpreter, which executes whatever
  # its arguments say — that stays a finding unless the arguments are
  # literal too, on every path, as far as this function's body shows
  # (`fixed_command?/3`; `Argus.Extractors.ParamFlow` asks again across
  # the module's local helpers). A command `find_executable/1` found for
  # a literal name is that program wherever PATH puts it (akkoma's
  # `ffprobe`), and is read as the name.
  defp read(:unless_static_command, ctx, _mfa, facts, _rel) do
    {scope, key} = Argv.function(ctx.instrs)
    if fixed_command?(ctx, scope, key), do: {:skip, facts}, else: {:pass, facts}
  end

  # Template bindings do not become source code. A literal source remains trusted
  # even when its bindings contain caller data; an unknown source remains a sink.
  defp read(:unless_literal_source, ctx, _mfa, facts, _rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, source} when is_binary(source) -> {:skip, facts}
      _ -> {:pass, facts}
    end
  end

  # A shell parses its command as code, but a fully literal command contains no
  # caller-selected source. Keep partial lists and joins with unknown alternatives.
  defp read(:unless_literal_command, ctx, _mfa, facts, _rel) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, source} -> if literal_command?(source), do: {:skip, facts}, else: {:pass, facts}
      _ -> {:pass, facts}
    end
  end

  # Which rpc:multicall/4 a site calls: multicall(Nodes, M, F, A) when
  # its third argument is a function name, its first a list of nodes or
  # its fourth an argument list; multicall(M, F, A, Timeout) when its
  # first is a module or its fourth a timeout. Arguments that say neither
  # (parameters handed on, say) leave it unknown.
  defp multicall_form(ctx) do
    value = &resolve_register(ctx.instrs, ctx.idx, {:x, &1})

    cond do
      match?({:ok, f} when is_atom(f) and f != :dynamic, value.(2)) -> :nodes
      match?({:ok, ns} when is_list(ns), value.(0)) -> :nodes
      match?({:ok, args} when is_list(args), value.(3)) -> :nodes
      match?({:ok, m} when is_atom(m) and m != :dynamic, value.(0)) -> :timeout
      match?({:ok, t} when is_integer(t) or t == :infinity, value.(3)) -> :timeout
      true -> :unknown
    end
  end

  defp literal_command?(source) when is_binary(source), do: true
  defp literal_command?([]), do: true

  defp literal_command?([head | tail]),
    do: (is_integer(head) or literal_command?(head)) and literal_command?(tail)

  defp literal_command?(_source), do: false

  # The finders a program's literal name is read through. `:os.find_executable/2`
  # searches the path it is handed: whatever file of that name sits
  # there runs, so the name says what it is only when the path is a
  # literal too.
  @finders [{System, :find_executable, 1}, {:os, :find_executable, 1}, {:os, :find_executable, 2}]

  defp static_command(ctx) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, c} when is_binary(c) ->
        {:ok, c}

      _ ->
        with {:ok, finder, at} when finder in @finders <-
               call_result_origin(ctx.instrs, ctx.idx, {:x, 0}),
             true <- literal_search_path?(finder, ctx.instrs, at),
             {:ok, name} <- resolve_register(ctx.instrs, at, {:x, 0}),
             name when is_binary(name) <- program_name(name) do
          {:ok, name}
        else
          _ -> :dynamic
        end
    end
  end

  defp literal_search_path?({:os, :find_executable, 2}, instrs, at),
    do:
      match?(
        {:ok, path} when is_list(path) or is_binary(path),
        resolve_register(instrs, at, {:x, 1})
      )

  defp literal_search_path?(_finder, _instrs, _at), do: true

  defp program_name(name) when is_binary(name), do: name

  defp program_name(name) when is_list(name),
    do: if(List.ascii_printable?(name), do: List.to_string(name))

  defp program_name(_name), do: nil

  defp rpc_callee(ctx, m, f) do
    with {:ok, mod} when is_atom(mod) and mod not in [nil, :dynamic] <-
           resolve_register(ctx.instrs, ctx.idx, {:x, m}),
         {:ok, fun} when is_atom(fun) and fun not in [nil, :dynamic] <-
           resolve_register(ctx.instrs, ctx.idx, {:x, f}),
         n when is_integer(n) <- Resolve.list_length(ctx.instrs, ctx.idx, {:x, f + 1}) do
      {inspect(mod), InstrId.func_id(mod, fun, n)}
    else
      _ -> nil
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
