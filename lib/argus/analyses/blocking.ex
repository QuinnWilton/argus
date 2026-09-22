defmodule Argus.Analyses.Blocking do
  @moduledoc """
  A synchronous wait that can last forever or nest.

  Every finding here is a process waiting on another. The mechanism is a
  column or a relation; the concern is the wait.

  - `call_chain(from, to, kind, depth, inferred, caller_ms,
    downstream_ms)` — synchronous hops through callbacks: a `chain` of
    `depth` `handle_call` hops whose per-hop timeouts compose
    unpredictably (a slow leaf times out every caller), a `cast` handler
    that makes a synchronous call (the mailbox backs up invisibly), or a
    `budget` where the caller's timeout is shorter than the callee's own
    downstream budget.
  - `call_cycle(mod_a, mod_b, witness_a, witness_b, phase)` — two modules
    that synchronously call each other, anywhere (`call`) or both from
    `handle_continue/2` (`continue`: a startup deadlock); the edges in
    `call_cycle_path` are its related frames, marked `tag` when the hop
    was attributed by message tag.
  - `sync_call_fan_in(target, count)` — a server five or more modules
    call synchronously; the callers in `bottleneck_caller` are its
    related frames.
  - `receive_in_callback(id, func, callback, behaviour, proximity,
    bounded)` — a `receive` on an OTP process's own stack, `bounded`
    false when it has no `after` and can hang.
  - `unbounded_wait(func, site, kind, api, detail)` — a wait with no
    deadline: `infinity` on a hop that itself serves synchronous callers,
    an `rpc` with the default infinity timeout, an `rpc_in_callback`
    (remote latency becomes local unavailability), or a `global` lock
    with retries (one distributed lock every caller shares).
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

  @impl true
  def output_relations do
    [
      %{
        name: :call_chain,
        fields: [
          {:from, :symbol, "the calling GenServer module"},
          {:to, :symbol, "the module it waits on"},
          {:kind, :symbol, "chain | cast | budget"},
          {:depth, :number, "handle_call hops for a chain (>= 2), 1 otherwise"},
          {:inferred, :symbol,
           "for a chain, 'tag' when a hop is attributed by message tag, else 'static'"},
          {:caller_ms, :number, "for a budget, the caller's timeout"},
          {:downstream_ms, :number, "for a budget, the callee's downstream timeout"}
        ],
        # One chain finding per (from, to) pair: the depth relation is
        # recursive with only a `from != to` guard, so a genuine cycle
        # emits a row at every depth up to the cap.
        key: [:from, :to, :kind, :caller_ms, :downstream_ms],
        doc: "Synchronous hops through callbacks whose timeouts compose, block, or do not fit."
      },
      %{
        name: :call_cycle,
        fields: [
          {:mod_a, :symbol, "first module in cycle"},
          {:mod_b, :symbol, "second module in cycle"},
          {:witness_a, :symbol, "function in mod_a carrying the a→b dependency"},
          {:witness_b, :symbol, "function in mod_b carrying the b→a return path"},
          {:phase, :symbol, "call (anywhere) | continue (both from handle_continue/2)"}
        ],
        key: [:mod_a, :mod_b, :phase],
        doc: "Pair of modules with mutual synchronous dependency."
      },
      %{
        name: :call_cycle_path,
        fields: [
          {:mod_a, :symbol, "first module of the cycle"},
          {:mod_b, :symbol, "second module of the cycle"},
          {:from_mod, :symbol, "source module of the edge"},
          {:to_mod, :symbol, "target module of the edge"},
          {:witness, :symbol, "function in from_mod carrying the dependency"},
          {:how, :symbol, "'tag' when the edge is attributed by message tag, else 'static'"}
        ],
        key: [:mod_a, :mod_b, :from_mod, :to_mod],
        evidence: %{of: :call_cycle, on: [:mod_a, :mod_b]},
        doc: "The edges of a call cycle, attached to its finding."
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
        evidence: %{of: :sync_call_fan_in, on: [:target_mod]},
        doc: "The callers of a high-fan-in (>= 5) GenServer, attached to its finding."
      },
      %{
        name: :receive_in_callback,
        fields: [
          {:id, :symbol, "instruction ID of the receive"},
          {:func, :symbol, "function containing the receive"},
          {:callback, :symbol, "the OTP callback it runs under"},
          {:behaviour, :symbol, "the behaviour that owns the process loop"},
          {:proximity, :symbol, "direct (in the callback) | helper (one call away)"},
          {:bounded, :symbol, "false when the receive has no after clause"}
        ],
        key: [:id],
        doc: "A receive on an OTP process's own stack, with or without a timeout."
      },
      %{
        name: :unbounded_wait,
        fields: [
          {:func, :symbol, "the waiting function (the handle_call/3, for infinity)"},
          {:site, :symbol, "instruction ID of the call, empty for infinity and rpc_in_callback"},
          {:kind, :symbol, "infinity | rpc | rpc_in_callback | global"},
          {:api, :symbol, "the call target, rpc variant, or :global operation"},
          {:detail, :symbol, "for global, the resolved retries"}
        ],
        key: [:func, :kind, :api, :detail],
        doc: "A wait with no deadline: an :infinity hop, an rpc, a cluster-wide lock."
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
  def finding(:call_chain, [from, to, "chain", depth, inferred, _, _]) do
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

  def finding(:call_chain, [mod, target, "cast", _, _, _, _]) do
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

  def finding(:call_chain, [caller, callee, "budget", _, _, caller_timeout, downstream_timeout]) do
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

  def finding(:unbounded_wait, [func, _, "infinity", target, _]) do
    mod = String.replace_suffix(func, ":handle_call/3", "")

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

  def finding(:call_cycle, [mod_a, mod_b, _wa, _wb, "continue"]) do
    Findings.new(
      :error,
      "Mutual handle_continue deadlock",
      "#{mod_a} and #{mod_b} sync-call each other from handle_continue/2. " <>
        "Both return from init — the supervisor proceeds happily — then each " <>
        "blocks calling the other before ever reading its own mailbox. " <>
        "Neither can reply; both calls time out, forever, on every boot.",
      at: Findings.at_mfa(mod_a, :handle_continue, 2),
      at_label: "one side of the cycle blocks here",
      help: [
        "break the cycle: keep one direction synchronous and make the other " <>
          "asynchronous (a cast, or a message each side processes once both " <>
          "are up)"
      ],
      related: [Findings.related("cycle partner", Findings.at_mfa(mod_b, :handle_continue, 2))]
    )
  end

  def finding(:call_cycle, [mod_a, mod_b, witness_a, witness_b, "call"]) do
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

  @impl true
  def evidence(:call_cycle_path, [_a, _b, from_mod, to_mod, witness, how]) do
    label =
      case how do
        "tag" -> "cycle edge #{from_mod} → #{to_mod}, inferred from the message tag"
        _ -> "cycle edge #{from_mod} → #{to_mod}"
      end

    Findings.related(label, Findings.at_func(witness))
  end

  def evidence(:bottleneck_caller, [caller_mod, _target_mod, witness]) do
    Findings.related("caller #{caller_mod}", Findings.at_func(witness))
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

  def finding(:receive_in_callback, [id, func, callback, behaviour, proximity, "false"]) do
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

  def finding(:receive_in_callback, [id, func, callback, behaviour, proximity, "true"]) do
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

  def finding(:unbounded_wait, [func, site, "rpc", variant, _]) do
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

  def finding(:unbounded_wait, [func, _, "rpc_in_callback", variant, _]) do
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

  def finding(:unbounded_wait, [func, site, "global", op, retries]) do
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
