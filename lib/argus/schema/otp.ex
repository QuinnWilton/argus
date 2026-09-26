defmodule Argus.Schema.Otp do
  @moduledoc """
  OTP processes and their callbacks: the names a module starts under,
  its links, the behaviours it implements, the calls and casts it makes,
  and what its callbacks return.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :named_process,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:name, :symbol, "registered process name"}
        ],
        doc: "Named process registration detected in code."
      },
      %{
        name: :process_link,
        layer: 2,
        fields: [
          {:from_mod, :symbol, "linking module"},
          {:to_mod, :symbol, "linked module"}
        ],
        doc: "Process link between modules."
      },
      %{
        name: :implements_behaviour,
        layer: 2,
        fields: [
          {:mod, :symbol, "implementing module"},
          {:behaviour, :symbol, "behaviour module"}
        ],
        doc: """
        Module declares a behaviour (`-behaviour`, `@behaviour`), as \
        `inspect/1` renders it (`":gen_server"`, `"GenServer"`). Rules ask \
        behaviours.dl's `behaves_as`, which also reads `started_as`.
        """
      },
      %{
        name: :started_as,
        layer: 2,
        fields: [
          {:mod, :symbol, "the callback module a start names"},
          {:behaviour, :symbol, "the behaviour of the start, as implements_behaviour spells it"}
        ],
        doc: """
        A start in the program (`gen_server:start_link(Name, Mod, Args, \
        Opts)`, `Supervisor.start_link(Mod, arg)`, `gen:start/5,6`, ...) or \
        an `enter_loop` names `mod` the callback module of `behaviour`, at \
        a call whose module argument is a literal module \
        (`Argus.Extractor.GenStarts`). The behaviour's machinery runs the \
        module's callbacks whether or not it declares the behaviour: \
        OTP's `inet_db` and `pg`, and ejabberd's `ejabberd_sql_sup`, \
        declare none. A `proc_lib` start names a function, and is none.
        """
      },
      %{
        name: :sync_call,
        layer: 2,
        fields: [
          {:caller_func, :symbol, "calling function ID"},
          {:callee_mod, :symbol, "target GenServer module"}
        ],
        doc: "GenServer.call target detected in code."
      },
      %{
        name: :async_cast,
        layer: 2,
        fields: [
          {:caller_func, :symbol, "calling function ID"},
          {:callee_mod, :symbol, "target GenServer module"}
        ],
        doc: "GenServer.cast target detected in code."
      },
      %{
        name: :sync_call_timeout,
        layer: 2,
        fields: [
          {:caller_func, :symbol, "calling function ID"},
          {:callee_mod, :symbol, "target GenServer module"},
          {:timeout_ms, :number, "timeout in ms (-1=infinity, 0=dynamic)"}
        ],
        doc: "GenServer.call timeout value at call site."
      },
      %{
        name: :sync_call_site,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:caller_func, :symbol, "calling function ID"},
          {:callee_mod, :symbol, "target GenServer module, or dynamic"},
          {:timeout_ms, :number, "timeout in ms (-1=infinity, 0=dynamic)"}
        ],
        doc: """
        A synchronous call's target and timeout at its site: what pairs a \
        dependency with the timeout of the call that makes it, where \
        sync_call_timeout says only that the function makes such a call.
        """
      },
      %{
        name: :sup_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the call site"},
          {:func, :symbol, "calling function ID"},
          {:api, :symbol,
           "the module: Supervisor, DynamicSupervisor, Task.Supervisor, " <>
             "PartitionSupervisor, or GenServer for stop"},
          {:op, :symbol, "the function: start_child, terminate_child, which_children, stop, ..."},
          {:target, :symbol,
           "the supervisor argument: a module atom, 'via:Registry', or 'dynamic'"}
        ],
        doc: """
        A synchronous management call into a supervisor process. Every one is \
        a GenServer.call underneath — `start_child` waits for the child's \
        init/1 to return, `terminate_child` for the child's whole shutdown — \
        but none names a GenServer module, so `sync_call` never saw them. \
        `target` is resolved from the first argument like `sync_call`'s callee.
        """
      },
      %{
        name: :callback_return,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the tuple construction"},
          {:func, :symbol, "the callback function"},
          {:callback, :symbol, "callback name: 'handle_call' | 'init' | ..."},
          {:tag, :symbol, "the literal return tag, e.g. ':reply' | ':noreply' | ':stop'"}
        ],
        doc: """
        A literal return tag of an OTP callback — the first element of a tuple \
        built into {x,0} immediately before `return`. Absent when the callback \
        tail-calls, since the shape then belongs to the callee; consumers must \
        treat absence as unknown rather than as "returns nothing".
        """
      },
      %{
        name: :callback_drops_from,
        layer: 2,
        fields: [
          {:id, :symbol, "the {:noreply, _} return site"},
          {:func, :symbol, "the handle_call/3 function"}
        ],
        doc: """
        A `{:noreply, _}` return site in handle_call/3 that some execution \
        reaches having never read `from`. Per site rather than per function, \
        because handle_call compiles every clause into one function and a \
        sibling clause that defers correctly would otherwise vouch for one \
        that does not.

        Established by walking the intra-function block graph from the entry \
        across blocks that do not read `from`. `from` arrives in {x,1}, and a \
        read is either a mention of that register or a call of arity two or \
        more, since calls take arguments positionally and a body passing \
        `from` straight through compiles to no move at all.
        """
      },
      %{
        name: :callback_stop_reason,
        layer: 2,
        fields: [
          {:id, :symbol, "the {:stop, ...} return site"},
          {:func, :symbol, "the callback function"},
          {:reason, :symbol, "the literal reason: ':normal', ':shutdown', or another atom"}
        ],
        doc: """
        The reason of a `{:stop, reason, ...}` return from an OTP callback, \
        when it is a literal atom or a `{:shutdown, term}` literal. Absent \
        when the reason is computed, so consumers treat absence as unknown.
        """
      },
      %{
        name: :callback_timeout,
        layer: 2,
        fields: [
          {:id, :symbol, "the return site"},
          {:func, :symbol, "the callback function"},
          {:callback, :symbol, "callback name: 'init' | 'handle_call' | ..."},
          {:timeout_ms, :number, "the literal timeout in milliseconds"}
        ],
        doc: """
        A literal integer timeout in an OTP callback's return — the third \
        element of `{:ok, state, ms}` or `{:noreply, state, ms}`, the fourth \
        of `{:reply, reply, state, ms}`. The message it schedules, `:timeout`, \
        is cancelled by any other message arriving first.
        """
      }
    ])
  end
end
