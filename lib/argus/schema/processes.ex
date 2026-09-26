defmodule Argus.Schema.Processes do
  @moduledoc """
  Process points-to: which process a pid can be, and the terms that hold
  one. Written by `Argus.Extractors.PidFlow`; chained across functions
  by clientlib/processes.dl. A source is a pair (src_kind, src).

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :process_start,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the start"},
          {:func, :func_id, "function containing the start"},
          {:proc, :symbol, "the process: \"<kind> <id>\""},
          {:kind, :symbol, "spawn, server or agent"},
          {:runs, :symbol, "the spawned function, the server's callback module, or dynamic"}
        ],
        doc: """
        A process allocation site: the start at `id` starts `proc`. A spawn \
        runs the function spawn_call resolved; a GenServer, :gen_server or \
        :gen_statem start runs its literal callback module, as does a \
        supervisor's start_child of a child spec naming one.
        """
      },
      %{
        name: :pid_arg,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, start or closure"},
          {:caller, :func_id, "function making the call"},
          {:callee, :func_id, "function whose parameter receives the value"},
          {:arg_pos, :symbol, "0-based parameter position, as a symbol"},
          {:via, :symbol, "call, init, spawn, child, closure, resolver or element"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        At `id`, `callee`'s parameter `arg_pos` may hold the source: a call \
        into project code (`call`), a server start's init argument \
        (`Mod:init/1`, `init`), a spawned function's arguments (`spawn`), a \
        child spec's argument (`Mod:start_link/1`, `child`) or a closure's \
        captured variables, its trailing parameters (`closure`). OTP's and \
        Elixir's own modules are not followed, but two of their calls hand a \
        function of the program a pid of another node, and those rows carry \
        only the `remote` source: a `:global` conflict resolver's second and \
        third parameters (`resolver`), and the first parameter of a fun \
        `Enum` or `:lists` runs on each element of a list of such pids \
        (`element`).
        """
      },
      %{
        name: :pid_return,
        layer: 2,
        fields: [
          {:func, :func_id, "function returning"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: "`func` may return the source, directly or by a tail call."
      },
      %{
        name: :pid_call,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, cast or send"},
          {:func, :func_id, "function making the call"},
          {:api_kind, :symbol,
           "call or cast (the sync_call/async_cast table), or info for a send"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        The GenServer-style call or cast at `id`, or the send (info), may \
        target the source or a literal name: what resolves a sync_call \
        recorded as "dynamic".
        """
      },
      %{
        name: :pid_message,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, cast or send"},
          {:func, :func_id, "function making the call, cast or send"},
          {:api_kind, :symbol, "call, cast or info (a send)"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        The message of the call, cast or send at `id` may be the source. It \
        reaches the handler of the server the pid_call rows of the same site \
        resolve to (handle_call/3, handle_cast/2, handle_info/2) as its \
        message parameter: how a subscriber's pid gets into a server's state.
        """
      },
      %{
        name: :pid_register,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the registration"},
          {:func, :func_id, "function registering"},
          {:name, :symbol, "the literal name"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc:
          "The call at `id` registers the source under `name` (Process.register/2, :erlang.register/2)."
      },
      %{
        name: :pid_send,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the send"},
          {:func, :func_id, "function sending"},
          {:message, :symbol,
           "literal atom, {:tag, …} for a tuple with a literal atom tag, or dynamic"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        The send at `id` (`send/2`, `!`, Process.send/3) goes to the source or, \
        with src_kind `name`, to a literal name. Keyed on the site because the \
        finding about what it sends anchors there.
        """
      },
      %{
        name: :pid_result,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function making the call"},
          {:callee, :func_id, "the project function called"}
        ],
        doc: "The project call at `id`, whose result is a `result` source (src = `id`)."
      },
      %{
        name: :pid_signal,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function making it"},
          {:signal, :symbol, "exit, monitor, link or unlink"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        The exit signal (Process.exit/2, :erlang.exit/2), monitor \
        (Process.monitor/1,2, :erlang.monitor/2,3), link or unlink at `id` goes \
        to the source.
        """
      },
      %{
        name: :pid_object,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:obj, :symbol, "the term: the instruction ID that built it"},
          {:shape, :symbol, "map, tuple or list"},
          {:tag, :symbol, "a tuple's literal atom first element, else empty"},
          {:arity, :symbol, "a tuple's size, else 0"}
        ],
        doc: """
        A term that holds a source, named by the instruction that built it \
        (put_map_*, put_tuple2, put_list, update_record, or a call whose \
        result has a known shape: a start's `{:ok, pid}`, `Map.put/3`).
        """
      },
      %{
        name: :pid_field,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:obj, :symbol, "the term"},
          {:sel, :symbol,
           "a map key (inspected), {i} for tuple position i (0-based), [] for a list's elements, * for an unknown map key"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: "The field `sel` of `obj` may hold the source."
      },
      %{
        name: :pid_base,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:obj, :symbol, "the term"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        `obj` updates the source: the fields `obj` does not set (pid_sets) are \
        the source's. A cons cell's base is its tail.
        """
      },
      %{
        name: :pid_sets,
        layer: 2,
        fields: [
          {:obj, :symbol, "the updated term"},
          {:sel, :symbol, "a field the update sets"}
        ],
        doc: "The update `obj` sets `sel`, shadowing its base's field."
      },
      %{
        name: :pid_load,
        layer: 2,
        fields: [
          {:func, :func_id, "function reading"},
          {:load, :symbol, "the load: the reading instruction's ID and the field"},
          {:sel, :symbol, "the field read, as in pid_field"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load, reply or remote"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to or the site that answered a pid of another node"}
        ],
        doc: """
        The load `load` (a `load` source in `func`) reads the field `sel` of \
        the source: `state.conn`, `elem(msg, 1)`, a clause head's \
        `{:subscribe, pid}`, `Map.get(state, :conn)`.
        """
      },
      %{
        name: :pid_remote,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing it"},
          {:api, :symbol, "the call, as `:global.whereis_name/1` spells it"}
        ],
        doc: """
        The call at `id` answers with a pid that may be another node's, or \
        hands one to a fun of the program: a `remote` source named by `id`. \
        A cluster-wide registry (`:global.whereis_name/1`, `GenServer.whereis/1` \
        of a `{:global, _}` or `{:via, :global | :syn | Horde.Registry | Swarm, _}` \
        name, `:syn`, Horde and Swarm lookups) answers with whichever node's \
        process holds the name; a process group (`:pg`, `:pg2`, `:syn` and \
        Swarm members) with every node's members; `Process.get(:"$callers")` \
        with the callers a process was started for, which a remote start \
        leaves on another node; `Process.info(pid, :links)` with links \
        that may cross nodes; and `:global.register_name/3` calls its \
        resolver with two pids on two nodes. A list of such pids keeps them \
        through `Enum.reverse/1`, `Enum.sort/1` and `Enum.uniq/1`. No process is allocated: \
        points-to resolves no `remote` source.
        """
      },
      %{
        name: :pid_probe,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing it"},
          {:bif, :symbol, "the call, as `:erlang.is_process_alive/1` spells it"},
          {:src_kind, :symbol, "where the pid comes from: remote, param, result or load"},
          {:src, :symbol,
           "the site that answered it, the parameter position, the call site or the load"}
        ],
        doc: """
        The call at `id` acts on a process of this node only and raises \
        badarg when handed another node's pid (`is_process_alive/1` and \
        `Process.alive?/1`, `process_info/1,2` and `Process.info/1,2`, \
        `garbage_collect/1,2`, `suspend_process/1,2`, `resume_process/1`, \
        `process_display/2`), and may be handed the source. A fun `Enum` or \
        `:lists` runs on each element of a list of such pids, when it is one \
        of these BIFs, is a probe at that call. A probe on the arm where a \
        test found `node(pid)` equal to another node (`node()`, most often) \
        is not recorded: the program asked where the pid lives first. One on \
        the other arm, or after the arms join, is.
        """
      },
      %{
        name: :table_alloc,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the :ets.new/2 call"},
          {:func, :func_id, "function containing it"},
          {:table, :symbol, "the table: \"table <id>\""}
        ],
        doc: """
        An ETS table allocation site, an object of the same points-to \
        analysis a process is: the reference an unnamed table is, or the \
        name a named table is answered with, flows from here as a `table` \
        source through parameters, returns, fields and a server's state.
        """
      },
      %{
        name: :table_use,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the :ets call"},
          {:func, :func_id, "function containing it"},
          {:src_kind, :symbol, "as in pid_arg, or table"},
          {:src, :symbol, "as in pid_arg, or the table"}
        ],
        doc: """
        The table operand of the ETS operation at `id` is the source: \
        clientlib/tables.dl chains it to the tables it may be.
        """
      },
      %{
        name: :start_error_compared,
        layer: 2,
        fields: [
          {:func, :func_id, "a function holding a creating op"},
          {:atom, :symbol, ":already_started | :already_registered"}
        ],
        doc: """
        The function compares against the atom somewhere — the loser of a \
        start race is taken. Any comparison anywhere counts, so an unrelated \
        one keeps the race rule quiet.
        """
      }
    ])
  end
end
