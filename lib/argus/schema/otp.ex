defmodule Argus.Schema.Otp do
  @moduledoc """
  Layer-2 OTP facts: registered names, links, behaviours, calls, casts, and callback \
  returns. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        A declared behaviour in `inspect/1` format. Rules use `behaves_as` in \
        `behaviours.dl`, which also incorporates `started_as`.
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
        A literal callback module named by a behaviour start or `enter_loop` \
        (`Argus.Extractor.GenStarts`). Identifies behaviour implementations even without \
        an explicit declaration. `proc_lib` starts name functions and are excluded.
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
        A synchronous call's target and timeout at one site. Unlike function-level \
        `sync_call_timeout`, preserves which dependency has that timeout.
        """
      },
      %{
        name: :async_cast_site,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the cast"},
          {:caller_func, :symbol, "casting function ID"},
          {:callee_mod, :symbol, "target GenServer module, or dynamic"}
        ],
        doc: """
        A cast's target at one site. Joins `call_tag` to associate the target and \
        message of the same cast.
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
        A synchronous supervisor management call, with the target resolved from its \
        first argument. These calls wait on the supervisor; starting a child waits for \
        init, and terminating one waits for shutdown.
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
        A literal OTP callback return tag built into `{x,0}` immediately before return. \
        Tail calls have no row because the callee supplies the shape. Absence means \
        unknown.
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
        A `handle_call/3` `{:noreply, _}` return reachable without reading `from`. \
        Traces paths that do not read `{x,1}` or call with arity at least two. Recorded \
        per return site so a correctly deferred sibling clause cannot hide a missing \
        reply.
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
        A literal reason in an OTP callback's `{:stop, reason, ...}` return: an atom or \
        `{:shutdown, term}` literal. Computed reasons have no row; absence means \
        unknown.
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
        A literal integer idle timeout in an OTP callback return. Schedules `:timeout`, \
        cancelled if another message arrives first.
        """
      }
    ])
  end
end
