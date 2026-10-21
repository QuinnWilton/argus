defmodule Argus.Schema.Processes do
  @moduledoc """
  Layer-2 value provenance and process operations from `Argus.Extractors.TermFlow`.
  General `value_*` summaries are composed by the shared Datalog stages.
  Sources use `(src_kind, src)` pairs. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :process_start,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the start"},
          {:func, :func_id, "function containing the start"},
          {:process, :symbol, "the process: \"<kind> <id>\""},
          {:kind, :symbol, "spawn, server or agent"},
          {:runs, :symbol, "the spawned function, the server's callback module, or dynamic"}
        ],
        doc: """
        A process allocation at start site `id`. Spawns use the resolved entry function; \
        server and child-spec starts use the literal callback module.
        """
      },
      %{
        name: :call_arg_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, start or closure"},
          {:caller, :func_id, "function making the call"},
          {:callee, :func_id, "function whose parameter receives the value"},
          {:arg_pos, :symbol, "0-based parameter position, as a symbol"},
          {:via, :symbol, "call, init, spawn, child, closure, resolver or element"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A possible source for callee parameter `arg_pos`: project call, init argument, \
        spawn argument, child-spec argument, trailing closure capture, or (`element`) \
        what a library call running the program's fun hands it: an element, a pair, an \
        accumulator (`element_fun`). OTP and Elixir internals are otherwise excluded, \
        except remote-pid inputs to global conflict resolvers.
        """
      },
      %{
        name: :return_var,
        layer: 2,
        fields: [
          {:func, :func_id, "function returning"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: "`func` may return the source, directly or by a tail call."
      },
      %{
        name: :process_call_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, cast or send"},
          {:func, :func_id, "function making the call"},
          {:api_kind, :symbol,
           "call or cast (the sync_call/async_cast table), or info for a send"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A possible target source or literal name for a call, cast, or info send. \
        Resolves targets recorded as `dynamic` by `sync_call`.
        """
      },
      %{
        name: :process_message_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call, cast or send"},
          {:func, :func_id, "function making the call, cast or send"},
          {:api_kind, :symbol, "call, cast or info (a send)"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A possible source for a call, cast, or send message. Flows to the corresponding \
        handler of the server resolved by the same site's `process_call_var` rows.
        """
      },
      %{
        name: :process_register_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the registration"},
          {:func, :func_id, "function registering"},
          {:name, :symbol, "the literal name"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc:
          "The call at `id` registers the source under `name` (Process.register/2, :erlang.register/2)."
      },
      %{
        name: :process_send_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the send"},
          {:func, :func_id, "function sending"},
          {:message, :symbol,
           "literal atom, {:tag, …} for a tuple with a literal atom tag, or dynamic"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A send target source, or a literal name with `src_kind` value `name`. Keyed by \
        send site for finding anchors.
        """
      },
      %{
        name: :call_result_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function making the call"},
          {:callee, :func_id, "the project function called"}
        ],
        doc: "The project call at `id`, whose result is a `result` source (src = `id`)."
      },
      %{
        name: :process_signal_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function making it"},
          {:signal, :symbol, "exit, monitor, link, unlink or stop"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A target source for an exit signal, monitor, link, unlink, or process stop, \
        including supervisor termination by pid.
        """
      },
      %{
        name: :send_envelope,
        layer: 2,
        fields: [{:id, :instr_id, "instruction ID of the send"}],
        doc: """
        A send of a behaviour envelope identified by tag and size: `$gen_call`, \
        `$gen_cast`, or `system`. Adds shape information beyond `process_send_var`'s tuple tag.
        """
      },
      %{
        name: :term_allocation,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:term, :symbol, "the term: the instruction ID that built it"},
          {:shape, :symbol, "map, tuple or list"},
          {:tag, :symbol, "a tuple's literal atom first element, else empty"},
          {:arity, :symbol, "a tuple's size, else 0"}
        ],
        doc: """
        A term containing a source, identified by its construction instruction. Includes \
        maps, tuples, lists, records, and calls with known result shapes such as process \
        starts or `Map.put/3`.
        """
      },
      %{
        name: :field_store,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:term, :symbol, "the term"},
          {:field, :symbol,
           "a map key (inspected), {i} for tuple position i (0-based), [] for a list's elements, * for an unknown map key"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: "The field `sel` of `obj` may hold the source."
      },
      %{
        name: :term_update_base,
        layer: 2,
        fields: [
          {:func, :func_id, "function building the term"},
          {:term, :symbol, "the term"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        An object's base source. Fields absent from `term_update_overwrites` retain the source's \
        values; a cons cell's base is its tail.
        """
      },
      %{
        name: :term_update_overwrites,
        layer: 2,
        fields: [
          {:term, :symbol, "the updated term"},
          {:field, :symbol, "a field the update sets"}
        ],
        doc: "The update `obj` sets `sel`, shadowing its base's field."
      },
      %{
        name: :field_load,
        layer: 2,
        fields: [
          {:func, :func_id, "function reading"},
          {:load, :symbol, "the load: the reading instruction's ID and the field"},
          {:field, :symbol, "the field read, as in field_store"},
          {:var_kind, :symbol,
           "where the value comes from: process, param, result, name, self, term, load, reply, remote, dictionary or table"},
          {:var, :symbol,
           "the process, the parameter position, the call site, the name, self, the term, the load, the call site replied to, the site that answered a pid of another node or the dictionary key"}
        ],
        doc: """
        A load reading selector `sel` from a source, including field access, tuple \
        extraction, pattern matching, and `Map.get/2`.
        """
      },
      %{
        name: :field_load_match,
        layer: 2,
        fields: [
          {:load, :symbol, "the load, as in field_load"},
          {:tag, :symbol, "the tag the match tested, or \"\" when it tested the arity alone"},
          {:arity, :symbol, "the arity the match tested"}
        ],
        doc: """
        The tuple element load `load` runs only once a match established its \
        source a tuple of `arity` elements, tagged `tag`.
        """
      },
      %{
        name: :process_remote_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing it"},
          {:api, :symbol, "the call, as `:global.whereis_name/1` spells it"}
        ],
        doc: """
        A call producing potentially remote pids or passing them to a fun. Covers \
        distributed registries and groups, `$callers`, process links, and global \
        conflict resolvers. Reverse, sort, and uniq preserve remote-pid lists. The \
        source is `remote`, named by call site; it represents no allocation and has no \
        points-to target.
        """
      },
      %{
        name: :process_probe_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing it"},
          {:bif, :symbol, "the call, as `:erlang.is_process_alive/1` spells it"},
          {:var_kind, :symbol, "where the pid comes from: remote, param, result or load"},
          {:var, :symbol,
           "the site that answered it, the parameter position, the call site or the load"}
        ],
        doc: """
        A local-only process operation receiving a possible source; remote pids can \
        raise `badarg`. Includes such BIFs passed as per-element funs to `Enum` or \
        `:lists`. Excludes sites restricted to the branch where `node(pid)` matches the \
        compared node; other branches and joined paths remain.
        """
      },
      %{
        name: :table_allocation,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the :ets.new/2 call"},
          {:func, :func_id, "function containing it"},
          {:table, :symbol, "the table: \"table <id>\""}
        ],
        doc: """
        An ETS allocation represented as a `table` points-to source. Its reference or \
        registered name flows through parameters, returns, fields, and server state.
        """
      },
      %{
        name: :table_use,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the :ets call"},
          {:func, :func_id, "function containing it"},
          {:var_kind, :symbol, "as in call_arg_var, or table"},
          {:var, :symbol, "as in call_arg_var, or the table"}
        ],
        doc: """
        An ETS operation's table source, resolved to possible allocations by \
        `clientlib/tables.dl`.
        """
      },
      %{
        name: :dictionary_operation,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing it"},
          {:operation, :symbol, "put, get or erase"},
          {:key, :symbol, "the literal key, or dynamic"}
        ],
        doc: """
        A process-dictionary put, get, or erase, including Elixir wrappers. `erase/0` \
        uses an unknown key.
        """
      },
      %{
        name: :dictionary_put,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the put"},
          {:func, :func_id, "function containing it"},
          {:key, :symbol, "the literal key"},
          {:var_kind, :symbol, "as in call_arg_var"},
          {:var, :symbol, "as in call_arg_var"}
        ],
        doc: """
        A source stored under `key` in the running process's dictionary. Reads of the \
        same `dict` source in that process may resolve to it (`clientlib/processes.dl`).
        """
      },
      %{
        name: :element_fun,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the library call"},
          {:caller, :func_id, "function making the call"},
          {:fun, :func_id, "the program's function the call runs: a closure or a capture"},
          {:answers, :symbol,
           "kept: the call's answer holds what fun answers; dropped: the call drops it"}
        ],
        doc: """
        A library call (`Enum.map/2`, `Enum.reduce/3`, `Map.new/2`, `:lists.foldl/3`, \
        ...) running `fun` on each element in the calling process \
        (`Argus.Extractors.TermFlow.Library`). `fun` is handed the elements (a map's \
        `{key, value}` pairs, a fold's accumulator) as `element` value_args; when the \
        call's answer holds what `fun` answers, a `call_result_var` row names `fun` as its \
        callee. Otherwise (`Enum.each/2`, `Enum.filter/2`, ...) what `fun` answers is \
        dropped.
        """
      },
      %{
        name: :task_operation_var,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the Task call"},
          {:func, :func_id, "function making it"},
          {:operation, :symbol, "await, await_many, yield, yield_many, shutdown or ignore"},
          {:var_kind, :symbol, "as in call_arg_var"},
          {:var, :symbol, "as in call_arg_var"}
        ],
        doc: """
        A possible source for the task, or the term holding the tasks, a Task operation \
        is handed, including one the library runs on each element of a list \
        (`Enum.map(tasks, &Task.await/1)`).
        """
      },
      %{
        name: :unmodeled_use,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call or send"},
          {:func, :func_id, "function making it"},
          {:var_kind, :symbol, "as in call_arg_var"},
          {:var, :symbol, "as in call_arg_var"}
        ],
        doc: """
        A source handed where value flow does not follow it: an argument of a library \
        call `Argus.Extractors.TermFlow.Library` does not model (a send, `:ets.insert/2`, \
        `Agent.update/2`, `Enum.chunk_while/4`, a call running a fun the table does not \
        know), or of a dynamic `fun.(...)` or `apply`. What holds it may be kept, sent \
        or dropped where no summary says.
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
        An atom compared anywhere in the function, used to recognize handling of a lost \
        start race. Unrelated comparisons can also suppress the race finding.
        """
      }
    ])
  end
end
