defmodule Argus.Analyses.Blocking do
  @moduledoc """
  A synchronous wait that can last forever or nest.

  Every finding here is a process waiting on another. The mechanism is a
  column or a relation; the concern is the wait.

  - `timeout_chain_risk(from, to, depth, inferred)` — a request into
    `from` traverses `depth` synchronous `handle_call` hops. Per-hop
    timeouts compose unpredictably; a slow leaf times out every caller.
  - `blocking_cast_handler(mod, target)` — a `handle_cast/2` that makes a
    synchronous call: the mailbox backs up invisibly.
  - `timeout_insufficient(caller, callee, caller_timeout, downstream)` —
    the caller's timeout is shorter than the callee's own downstream
    budget.
  - `infinity_timeout_in_chain(mod, target)` — `:infinity` on a hop that
    itself serves synchronous callers.
  - `call_cycle(mod_a, mod_b, witness_a, witness_b)` — two modules that
    synchronously call each other; `call_cycle_path` is the evidence,
    one edge per row, marked `tag` when the hop was attributed by message
    tag.
  - `sync_call_fan_in(target, count)` and `bottleneck_caller(caller,
    target, witness)` — a server five or more modules call synchronously.
  - `blocking_receive_in_callback` and `receive_in_callback` — a
    `receive` on an OTP process's own stack, with and without a timeout.
  - `rpc_without_timeout(func, variant, site)` — a remote call with the
    default infinity timeout.
  - `rpc_in_genserver_callback(func, variant)` — remote latency inside a
    callback becomes local unavailability.
  - `global_blocking_op(func, op, retries, site)` — `:global.set_lock` or
    `:global.trans` with retries: one distributed lock every caller
    shares.
  - `partial_noproc_catch(func, site, callee)` — a peer call whose catch
    covers `:noproc` but not the peer stopping mid-call.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :blocking

  @impl true
  def description,
    do: "synchronous waits that can last forever or nest: chains, cycles, fan-in, rpc, locks"

  @impl true
  def rules_file, do: "analyses/blocking.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      # The sync_call rows the chains follow are partly derived through
      # call_arg and call_arg_forward: a target forwarded through a wrapper.
      Argus.Extractors.CallArgs,
      Argus.Extractors.ErrorHandling
    ]

  @fields [
    {:id, :symbol, "instruction ID of the receive"},
    {:func, :symbol, "function containing the receive"},
    {:callback, :symbol, "the OTP callback it runs under"},
    {:behaviour, :symbol, "the behaviour that owns the process loop"},
    {:proximity, :symbol, "direct (in the callback) | helper (one call away)"}
  ]

  @impl true
  def output_relations do
    [
      %{
        name: :timeout_chain_risk,
        fields: [
          {:from, :symbol, "outermost GenServer module"},
          {:to, :symbol, "innermost GenServer module"},
          {:depth, :number, "chain depth (>= 2)"},
          {:inferred, :symbol, "'tag' when a hop is attributed by message tag, else 'static'"}
        ],
        # One finding per (from, to) module pair. The depth relation is
        # recursive with only a `from != to` guard, so a genuine cycle
        # emits a row at every depth up to the cap; keying on the pair
        # collapses those to a single finding instead of one per depth.
        key: [:from, :to],
        doc: "Timeout chain through GenServer handle_call callbacks."
      },
      %{
        name: :blocking_cast_handler,
        fields: [
          {:mod, :symbol, "GenServer module with blocking cast"},
          {:target, :symbol, "sync call target module"}
        ],
        doc: "handle_cast/2 that makes a synchronous call."
      },
      %{
        name: :timeout_insufficient,
        fields: [
          {:caller, :symbol, "calling GenServer module"},
          {:callee, :symbol, "called GenServer module"},
          {:caller_timeout, :number, "caller's timeout (ms)"},
          {:callee_downstream_timeout, :number, "callee's downstream timeout (ms)"}
        ],
        doc: "Caller's timeout cannot accommodate callee's downstream sync call."
      },
      %{
        name: :infinity_timeout_in_chain,
        fields: [
          {:mod, :symbol, "GenServer module using :infinity timeout"},
          {:target, :symbol, "sync call target module"}
        ],
        doc: "Sync call in a chain uses :infinity timeout, can block forever."
      },
      %{
        name: :call_cycle,
        fields: [
          {:mod_a, :symbol, "first module in cycle"},
          {:mod_b, :symbol, "second module in cycle"},
          {:witness_a, :symbol, "function in mod_a carrying the a→b dependency"},
          {:witness_b, :symbol, "function in mod_b carrying the b→a return path"}
        ],
        key: [:mod_a, :mod_b],
        doc: "Pair of modules with mutual synchronous dependency."
      },
      %{
        name: :call_cycle_path,
        fields: [
          {:from_mod, :symbol, "source module"},
          {:to_mod, :symbol, "target module"},
          {:witness, :symbol, "function in from_mod carrying the dependency"},
          {:how, :symbol, "'tag' when the edge is attributed by message tag, else 'static'"}
        ],
        key: [:from_mod, :to_mod],
        doc: "Transitive sync dependency edge between cycle participants."
      },
      %{
        name: :sync_call_fan_in,
        fields: [
          {:target_mod, :symbol, "target GenServer module"},
          {:cnt, :number, "number of distinct caller modules"}
        ],
        doc: "Synchronous call fan-in count for a GenServer (>= 5 only)."
      },
      %{
        name: :bottleneck_caller,
        fields: [
          {:caller_mod, :symbol, "module making the sync call"},
          {:target_mod, :symbol, "target GenServer module"},
          {:witness, :symbol, "function in caller_mod making the call"}
        ],
        key: [:caller_mod, :target_mod],
        doc: "Caller of a high-fan-in (>= 5) GenServer."
      },
      %{
        name: :blocking_receive_in_callback,
        fields: @fields,
        key: [:id],
        doc: "A receive with no timeout, running on an OTP process's own stack."
      },
      %{
        name: :receive_in_callback,
        fields: @fields,
        key: [:id],
        doc: "A receive with a timeout, still consuming the behaviour's mailbox."
      },
      %{
        name: :rpc_without_timeout,
        fields: [
          {:func, :symbol, "function with infinity RPC"},
          {:variant, :symbol, "RPC variant"},
          {:site, :symbol, "instruction ID of the RPC call"}
        ],
        key: [:func, :variant],
        doc: "RPC call with default infinity timeout."
      },
      %{
        name: :rpc_in_genserver_callback,
        fields: [
          {:func, :symbol, "GenServer callback"},
          {:variant, :symbol, "RPC variant"}
        ],
        doc: "RPC inside GenServer callback (compounds timeout risk)."
      },
      %{
        name: :global_blocking_op,
        fields: [
          {:func, :symbol, "function calling :global"},
          {:op, :symbol, "operation: set_lock | trans | ..."},
          {:retries, :symbol, "resolved retries argument: infinity | positive integer"},
          {:site, :symbol, "instruction ID of the :global call"}
        ],
        key: [:func, :op, :retries],
        doc:
          "Blocking :global synchronization (set_lock or trans with infinity or positive retries)."
      },
      %{
        name: :partial_noproc_catch,
        fields: [
          {:func, :symbol, "function making the call"},
          {:site, :symbol, "the try"},
          {:callee, :symbol, "the guarded call"}
        ],
        key: [:func, :site],
        doc: "A peer call whose catch covers :noproc but not the peer stopping mid-call."
      }
    ]
  end

  @impl true
  def finding(:timeout_chain_risk, [from, to, depth, inferred]) do
    inferred_note =
      if inferred == "tag",
        do:
          " At least one hop is inferred: a call targets a pid or name held in " <>
            "state, attributed to the module whose handle_call/3 matches its tag.",
        else: ""

    Findings.new(
      :warning,
      "GenServer call chain of depth #{depth}",
      "A request into #{from} traverses #{depth} synchronous hops, ending at " <>
        "#{to}. GenServer.call's default 5000ms timeout applies per hop, so " <>
        "the deadlines compose unpredictably: a slow leaf times out every " <>
        "caller above it, and each level retries or crashes on its own " <>
        "schedule." <> inferred_note,
      at: Findings.at_mfa(from, :handle_call, 3),
      related: [Findings.related("innermost callee", Findings.at_module(to))],
      help:
        if(inferred == "tag",
          do: ["check the inferred hop: if that pid is a different server, the chain is shorter"],
          else: []
        )
    )
  end

  def finding(:blocking_cast_handler, [mod, target]) do
    Findings.new(
      :warning,
      "handle_cast blocks on a synchronous call",
      "#{mod}'s handle_cast/2 makes a GenServer.call to #{target}. Casts look " <>
        "fire-and-forget to senders, but the server still blocks — the " <>
        "mailbox backs up invisibly because no caller ever waits on (or " <>
        "notices) the slow handler.",
      at: Findings.at_mfa(mod, :handle_cast, 2),
      related: [Findings.related("call target", Findings.at_module(target))]
    )
  end

  def finding(:timeout_insufficient, [caller, callee, caller_timeout, downstream_timeout]) do
    Findings.new(
      :error,
      "Call timeout shorter than the callee's downstream budget",
      "#{caller} calls #{callee} with a #{caller_timeout}ms timeout, but " <>
        "#{callee}'s own downstream sync calls budget #{downstream_timeout}ms. " <>
        "The outer call can time out — crashing or retrying — while the inner " <>
        "work is still legitimately running, leaving duplicated effort and " <>
        "inconsistent state.",
      at: Findings.at_mfa(caller, :handle_call, 3),
      related: [Findings.related("callee", Findings.at_module(callee))]
    )
  end

  def finding(:infinity_timeout_in_chain, [mod, target]) do
    Findings.new(
      :warning,
      ":infinity timeout inside a call chain",
      "#{mod} calls #{target} with timeout :infinity while itself serving " <>
        "synchronous callers. If anything downstream hangs, this process " <>
        "hangs forever with it — no timeout ever unblocks the chain.",
      at: Findings.at_mfa(mod, :handle_call, 3),
      related: [Findings.related("call target", Findings.at_module(target))]
    )
  end

  def finding(:call_cycle, [mod_a, mod_b, witness_a, witness_b]) do
    Findings.new(
      :error,
      "Synchronous call cycle",
      "#{mod_a} and #{mod_b} synchronously call each other, directly or through " <>
        "intermediaries. If both directions are ever in flight at once, each " <>
        "process blocks waiting on the other's mailbox — a deadlock that " <>
        "GenServer.call timeouts only turn into cascading crashes. Break one " <>
        "direction with a cast or a message.",
      at: Findings.at_func(witness_a),
      related: [Findings.related("return path", Findings.at_func(witness_b))]
    )
  end

  def finding(:call_cycle_path, [from_mod, to_mod, witness, how]) do
    {detail, help} =
      case how do
        "tag" ->
          {"Synchronous dependency edge between call-cycle participants — the " <>
             "evidence behind a call_cycle finding. This edge is inferred: the call " <>
             "targets a pid or a name held in state, and #{to_mod} is the module " <>
             "whose handle_call/3 matches the message tag it sends.",
           ["if #{to_mod} is not the process behind that pid, the cycle is not real"]}

        _ ->
          {"Synchronous dependency edge between call-cycle participants — the " <>
             "evidence behind a call_cycle finding.", []}
      end

    Findings.new(
      :info,
      "Cycle edge: #{from_mod} → #{to_mod}",
      detail,
      at: Findings.at_func(witness),
      at_label: if(how == "tag", do: "inferred from the message tag", else: nil),
      related: [Findings.related("callee", Findings.at_module(to_mod))],
      help: help
    )
  end

  def finding(:sync_call_fan_in, [target_mod, cnt]) do
    Findings.new(
      :warning,
      "High synchronous fan-in (#{cnt} caller modules)",
      "#{cnt} distinct modules make GenServer.call into #{target_mod}. A " <>
        "single process serializes all of them — under load, queue depth and " <>
        "call latency grow together until callers start timing out. Consider " <>
        "sharding, ETS for reads, or casts where replies aren't needed.",
      at: Findings.at_mfa(target_mod, :handle_call, 3)
    )
  end

  def finding(:bottleneck_caller, [caller_mod, target_mod, witness]) do
    Findings.new(
      :info,
      "Caller of a high fan-in GenServer",
      "#{caller_mod} synchronously calls #{target_mod}, one of #{target_mod}'s " <>
        "five-plus caller modules. Each such call competes for the same " <>
        "serialized mailbox.",
      at: Findings.at_func(witness),
      related: [Findings.related("bottleneck", Findings.at_module(target_mod))]
    )
  end

  def finding(:blocking_receive_in_callback, [id, func, callback, behaviour, proximity]) do
    Findings.new(
      :error,
      "Blocking receive inside a #{behaviour} callback",
      "#{func} runs a `receive` with no `after`, #{where(proximity, callback)}. It " <>
        "executes on the #{behaviour} process's own stack, so it consumes from " <>
        "the mailbox the behaviour is managing: {:system, _, _} (which is how " <>
        ":sys.get_state and the debug surface reach the process), {:EXIT, _, _} " <>
        "when trapping, and every in-flight monitor's {:DOWN, ...}. With no " <>
        "timeout it can also block forever — the supervisor's shutdown then " <>
        "waits out the child timeout and brutal-kills, losing whatever the " <>
        "process was holding. Move the wait into a task and reply to the " <>
        "callback with a message, or handle the reply in handle_info.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:receive_in_callback, [id, func, callback, behaviour, proximity]) do
    Findings.new(
      :warning,
      "receive inside a #{behaviour} callback",
      "#{func} runs a `receive`, #{where(proximity, callback)}. It has a " <>
        "timeout so it cannot hang, but it still executes on the #{behaviour} " <>
        "process's own stack and selectively consumes from the mailbox the " <>
        "behaviour manages — including the system messages :sys and the " <>
        "supervisor rely on. Messages it does not match are left in the queue " <>
        "and re-scanned by every later receive.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:rpc_without_timeout, [func, variant, site]) do
    Findings.new(
      :warning,
      "RPC without a bounded timeout",
      "#{func} makes a #{variant} call with an infinity timeout (the " <>
        "default when none is passed, or `:infinity` given explicitly). A " <>
        "partitioned, overloaded, or restarting peer blocks this process " <>
        "indefinitely — distributed calls need explicit deadlines.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:rpc_in_genserver_callback, [func, variant]) do
    Findings.new(
      :warning,
      "RPC inside a GenServer callback",
      "#{func} performs #{variant} while its GenServer is blocked in a " <>
        "callback. Remote latency becomes local unavailability: every queued " <>
        "caller waits on the network round-trip, and a peer outage stalls " <>
        "the whole server.",
      at: Findings.at_func(func)
    )
  end

  def finding(:global_blocking_op, [func, op, retries, site]) do
    Findings.new(
      :info,
      "Cluster-wide :global synchronization",
      "#{func} calls :global.#{op} with retries = #{retries}. :global " <>
        "operations serialize across the whole cluster — fine when " <>
        "deliberate, but every caller shares one distributed lock, and " <>
        "partition recovery stalls them all.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:partial_noproc_catch, [func, site, callee]) do
    Findings.new(
      :warning,
      "Peer call catches :noproc but not :shutdown",
      "#{func} wraps #{callee} in a catch for `{:noproc, _}` — the peer may not " <>
        "exist — but the peer stopping while the call is in flight is the same " <>
        "condition, and it arrives as `{:shutdown, _}` (or `{:normal, _}`), which " <>
        "this catch lets crash the caller.",
      at: Findings.at_site(site, func),
      at_label: "catches only :noproc",
      help: [
        "add a clause for `:exit, {:shutdown, _}` (and `{:normal, _}`)",
        "or catch `:exit, reason` and classify it"
      ]
    )
  end

  defp where("direct", callback), do: "and #{callback} is that callback"
  defp where(_helper, callback), do: "reached directly from the callback #{callback}"
end
