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
    [
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
          {:via, :symbol, "call, init, spawn, child or closure"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
        ],
        doc: """
        At `id`, `callee`'s parameter `arg_pos` may hold the source: a call \
        into project code (`call`), a server start's init argument \
        (`Mod:init/1`, `init`), a spawned function's arguments (`spawn`), a \
        child spec's argument (`Mod:start_link/1`, `child`) or a closure's \
        captured variables, its trailing parameters (`closure`). OTP's and \
        Elixir's own modules are not followed.
        """
      },
      %{
        name: :pid_return,
        layer: 2,
        fields: [
          {:func, :func_id, "function returning"},
          {:src_kind, :symbol,
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
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
           "where the value comes from: proc, param, result, name, self, obj, load or reply"},
          {:src, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load or the call site replied to"}
        ],
        doc: """
        The load `load` (a `load` source in `func`) reads the field `sel` of \
        the source: `state.conn`, `elem(msg, 1)`, a clause head's \
        `{:subscribe, pid}`, `Map.get(state, :conn)`.
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
    ]
  end
end
