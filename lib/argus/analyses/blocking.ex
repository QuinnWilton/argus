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
  - `call_cycle(mod_a, mod_b, witness_a, witness_b, phase, site_a,
    site_b)` — two modules
    whose processes synchronously call each other (`call`: each witness
    runs on its module's own process, reached from a callback; a wait
    made only while an unnamed process starts counts only where the
    peer's handler calls it back) or both from `handle_continue/2`
    (`continue`: a startup deadlock); the edges in
    `call_cycle_path` are its related frames, marked `tag` when the hop
    was attributed by message tag. `self` is the cycle of one: a
    synchronous call to the calling process itself, which gen exits with
    `:calling_self`.
  - `sync_call_fan_in(target, count)` — a server five or more modules
    call synchronously; the callers in `bottleneck_caller` are its
    related frames.
  - `receive_in_callback(id, func, callback, behaviour, proximity,
    bounded)` — a `receive` on an OTP process's own stack, `bounded`
    false when it has no `after` and can hang, true when it has one, down
    when it has none but takes the `:DOWN` of a monitor its function
    took, and so ends no later than the monitored process.
  - `unbounded_wait(func, site, kind, api, detail, nodes)` — a wait with
    no deadline: `infinity` on a hop that itself serves synchronous
    callers, an `rpc` with the default infinity timeout, an
    `rpc_in_callback` (remote latency becomes local unavailability), or a
    `global` lock with retries (one distributed lock every caller shares
    when `nodes` is `cluster` or `unknown`; a lock on this node alone
    when it is `local`), or a `socket` call with no timeout (a recv, a
    connect, a TLS handshake) that a callback of `detail`, the server,
    runs on its own stack.
  - `partial_noproc_catch(func, site, callee, call, guard_end)` — a peer call whose catch
    covers `:noproc` but not the peer stopping mid-call.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :blocking

  @impl true
  def description,
    do:
      "synchronous waits that can last forever or nest: call chains, cycles, fan-in, rpc, " <>
        "locks, receives in callbacks"

  @impl true
  def rules_file, do: "analyses/blocking.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      # The clause of a handle_call/3, or of a guarded dispatcher, each
      # call runs in: a chain follows the clause a request enters.
      Argus.Extractors.ClauseCall,
      # The sync_call rows the chains follow are partly derived through
      # call_arg and call_arg_forward: a target forwarded through a wrapper.
      Argus.Extractors.CallArgs,
      Argus.Extractors.ErrorHandling,
      # A receive that takes the :DOWN of a monitor its function took ends
      # no later than the monitored process (recv_down).
      Argus.Extractors.Monitor,
      # A call whose target is a pid resolves through process points-to
      # (clientlib/processes.dl, in the points-to stage): where the pid was
      # started, and names.
      Argus.Extractors.PidFlow,
      Argus.Extractors.ProcessRegistry,
      # A GenServer a child spec names is a server process too.
      Argus.Extractors.Supervision,
      # A gen_statem's state functions and data (clientlib/process_statem.dl,
      # and processes.dl in the points-to stage).
      Argus.Extractors.GenStatem,
      # Socket calls and how long they wait (unbounded_wait's "socket").
      Argus.Extractors.Sockets,
      # A handle_call/3 that returns {:noreply, _} answers later
      # (callback_return, clientlib/replies.dl): no immediate answer.
      Argus.Extractors.Reply
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
          {:witness_a, :symbol, "function mod_a's process runs that carries the a→b dependency"},
          {:witness_b, :symbol, "function mod_b's process runs that carries the b→a return path"},
          {:phase, :symbol,
           "call (their processes, from their callbacks) | continue (both from handle_continue/2) | " <>
             "self (a process calling itself; mod_a = mod_b)"},
          {:site_a, :symbol, "the call in witness_a, when direct; else empty"},
          {:site_b, :symbol, "the call in witness_b, when direct; else empty"}
        ],
        # A self-call is one finding per call site.
        key: {:phase, %{"self" => [:witness_a, :site_a], default: [:mod_a, :mod_b, :phase]}},
        doc: "Pair of modules with mutual synchronous dependency, or a process calling itself."
      },
      %{
        name: :call_cycle_path,
        fields: [
          {:mod_a, :symbol, "first module of the cycle"},
          {:mod_b, :symbol, "second module of the cycle"},
          {:from_mod, :symbol, "source module of the edge"},
          {:to_mod, :symbol, "target module of the edge"},
          {:witness, :symbol, "function in from_mod carrying the dependency"},
          {:how, :symbol, "'tag' when the edge is attributed by message tag, else 'static'"},
          {:site, :symbol, "the call in the witness, when direct; else empty"}
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
          {:bounded, :symbol,
           "false when the receive has no after clause, true when it has one, " <>
             "down when it has none but takes the :DOWN of a monitor its function took"}
        ],
        key: [:id],
        doc: "A receive on an OTP process's own stack, with or without a timeout."
      },
      %{
        name: :unbounded_wait,
        fields: [
          {:func, :symbol, "the waiting function (the handle_call/3, for infinity)"},
          {:site, :symbol, "instruction ID of the call, empty for infinity and rpc_in_callback"},
          {:kind, :symbol, "infinity | rpc | rpc_in_callback | global | socket"},
          {:api, :symbol, "the call target, rpc variant, or :global operation"},
          {:detail, :symbol,
           "for global, the resolved retries; for rpc, 'caller' when the timeout is a " <>
             "parameter a caller passes as :infinity (rpc_infinity_caller); for socket, " <>
             "the server whose callback runs the call"},
          {:nodes, :symbol,
           "for global, the nodes the lock waits on: cluster | local | unknown; else empty"}
        ],
        key: [:func, :kind, :api, :detail, :nodes],
        doc: "A wait with no deadline: an :infinity hop, an rpc, a cluster-wide lock."
      },
      %{
        name: :rpc_infinity_caller,
        fields: [
          {:func, :symbol, "the function making the rpc"},
          {:site, :symbol, "the rpc call instruction"},
          {:caller, :symbol, "a function that passes :infinity as its timeout parameter"}
        ],
        key: [:func, :site, :caller],
        evidence: %{of: :unbounded_wait, on: [:func, :site]},
        doc:
          "The callers that pass :infinity to an rpc's timeout parameter, attached to its finding."
      },
      %{
        name: :partial_noproc_catch,
        fields: [
          {:func, :symbol, "function making the call"},
          {:site, :symbol, "the try"},
          {:callee, :symbol, "the guarded call"},
          {:call, :symbol, "the guarded call's instruction"},
          {:guard_end, :symbol, "the catch's last instruction"}
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
      at_label: "a request enters the chain here",
      related: [Findings.related("innermost callee", Findings.at_module(to))],
      help:
        [
          "give each hop a timeout that fits inside its caller's, or let the leaf " <>
            "answer the original caller directly"
        ] ++
          if(inferred == "tag",
            do: [
              "check the inferred hop: if that pid is a different server, the chain is shorter"
            ],
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
      at_label: "this handle_cast blocks on a call",
      related: [Findings.related("call target", Findings.at_module(target))],
      help: [
        "have #{target} answer asynchronously (a cast back, or a message), " <>
          "or run the call in a task and take its reply in handle_info/2"
      ]
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
      at_label: "this call's timeout is shorter than what it waits for",
      related: [Findings.related("callee", Findings.at_module(callee))],
      help: [
        "raise the caller's timeout past #{downstream_timeout}ms, or shorten " <>
          "#{callee}'s downstream calls to fit inside #{caller_timeout}ms"
      ]
    )
  end

  def finding(:unbounded_wait, [func, _, "infinity", target, _, _]) do
    mod = String.replace_suffix(func, ":handle_call/3", "")

    Findings.new(
      :warning,
      ":infinity timeout inside a call chain",
      "#{mod} calls #{target} with timeout :infinity while itself serving " <>
        "synchronous callers. If anything downstream hangs, this process " <>
        "hangs forever with it — no timeout ever unblocks the chain.",
      at: Findings.at_mfa(mod, :handle_call, 3),
      at_label: "waits with :infinity while serving callers",
      related: [Findings.related("call target", Findings.at_module(target))],
      help: [
        "pass a finite timeout and handle the exit, or move the wait off " <>
          "the process that serves callers"
      ]
    )
  end

  def finding(:call_cycle, [mod_a, mod_b, _wa, _wb, "continue", _sa, _sb]) do
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

  def finding(:call_cycle, [mod, mod, func, func, "self", site, site]) do
    Findings.new(
      :error,
      "Synchronous call to the calling process itself",
      "#{Findings.call_name(func)} makes a synchronous call whose target is the " <>
        "process running it: self(), or a name only #{mod}'s own process holds. " <>
        "A process cannot answer a call while it waits for the reply, so gen " <>
        "exits the caller with :calling_self instead of deadlocking, and the " <>
        "process crashes on the first call.",
      at: Findings.at_site_in_func(site, func, mod),
      at_label: "calls its own process",
      help: [
        "call the function that does the work directly, or send the process " <>
          "a message (`send(self(), msg)`, a cast) and handle it later"
      ]
    )
  end

  def finding(:call_cycle, [mod_a, mod_b, witness_a, witness_b, "call", site_a, site_b]) do
    Findings.new(
      :error,
      "Synchronous call cycle",
      "#{mod_a} and #{mod_b} synchronously call each other, directly or through " <>
        "intermediaries. If both directions are ever in flight at once, each " <>
        "process blocks waiting on the other's mailbox — a deadlock that " <>
        "GenServer.call timeouts only turn into cascading crashes.",
      at: Findings.at_site_in_func(site_a, witness_a, mod_a),
      at_label: "one direction of the cycle",
      related: [
        Findings.related("return path", Findings.at_site_in_func(site_b, witness_b, mod_b))
      ],
      help: ["break one direction with a cast or a message"]
    )
  end

  def finding(:sync_call_fan_in, [target_mod, cnt]) do
    Findings.new(
      :warning,
      "High synchronous fan-in (#{cnt} caller modules)",
      "#{cnt} distinct modules make GenServer.call into #{target_mod}. A " <>
        "single process serializes all of them — under load, queue depth and " <>
        "call latency grow together until callers start timing out.",
      at: Findings.at_mfa(target_mod, :handle_call, 3),
      at_label: "#{cnt} modules call this server",
      help: ["shard the server, serve reads from ETS, or use casts where no reply is needed"]
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
        "process was holding.",
      at: Findings.at_instr(id),
      to_block: :receive,
      at_label: "blocking receive on the callback's own stack",
      help: [
        "move the wait into a task and reply to the callback with a message, " <>
          "or handle the reply in handle_info/2"
      ]
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
      at: Findings.at_instr(id),
      to_block: :receive,
      at_label: "receive on the callback's own stack",
      help: ["take the message in handle_info/2 instead of a receive inside the callback"]
    )
  end

  def finding(:receive_in_callback, [id, func, callback, behaviour, proximity, "down"]) do
    Findings.new(
      :warning,
      "receive inside a #{behaviour} callback",
      "#{func} runs a `receive` with no `after`, #{where(proximity, callback)}, " <>
        "and it takes the :DOWN of the process it monitored: the runtime sends " <>
        "that once the process exits, or at once if it was already gone, so the " <>
        "wait cannot outlast it. Until then it holds the #{behaviour} process on " <>
        "its own stack, and :sys calls and queued requests wait behind it.",
      at: Findings.at_instr(id),
      to_block: :receive,
      at_label: "waits for the monitored process to exit",
      help: [
        "if that process may linger, give the wait an `after` that kills it " <>
          "and waits for the :DOWN again, as Task.shutdown/2 does"
      ]
    )
  end

  def finding(:unbounded_wait, [func, site, "rpc", variant, "caller", _]) do
    Findings.new(
      :warning,
      "RPC without a bounded timeout",
      "#{func} calls #{Findings.rpc_api(variant)} with the timeout it takes as a " <>
        "parameter, and a caller passes `:infinity` there (a default argument, " <>
        "`timeout \\\\ :infinity`, does this). Through that caller, a peer that " <>
        "stays connected but never answers holds this process forever. A node " <>
        "that goes away is noticed only after net_ticktime, about a minute by default.",
      at: Findings.at_instr(site),
      at_label: "a caller passes :infinity as this timeout",
      help: [rpc_timeout_help(variant) <> ", and give the parameter a finite default"]
    )
  end

  def finding(:unbounded_wait, [func, site, "rpc", variant, _, _]) do
    Findings.new(
      :warning,
      "RPC without a bounded timeout",
      "#{func} calls #{Findings.rpc_api(variant)} with an infinity timeout (the " <>
        "default when none is passed, or `:infinity` given explicitly). A peer " <>
        "that stays connected but never answers, its callee deadlocked or " <>
        "waiting on something that never comes, holds this process forever. " <>
        "A node that goes away is noticed only after net_ticktime, about a " <>
        "minute by default.",
      at: Findings.at_instr(site),
      at_label: "no timeout bounds this call",
      help: [rpc_timeout_help(variant)]
    )
  end

  def finding(:unbounded_wait, [func, _, "rpc_in_callback", variant, _, _]) do
    Findings.new(
      :warning,
      "RPC inside a GenServer callback",
      "#{func} calls #{Findings.rpc_api(variant)} while its GenServer is blocked in a " <>
        "callback. Remote latency becomes local unavailability: every queued " <>
        "caller waits on the network round-trip, and a peer outage stalls " <>
        "the whole server.",
      at: Findings.at_func(func),
      at_label: "remote call inside a callback",
      help: ["make the remote call from a task and take its reply in handle_info/2"]
    )
  end

  def finding(:unbounded_wait, [func, site, "socket", api, server, _]) do
    Findings.new(
      :warning,
      "Socket call with no timeout inside a callback",
      "#{Findings.call_name(func)} calls #{api}, which #{socket_wait(api)}, and " <>
        "#{server}'s callbacks run it on the server's own stack. While it waits the " <>
        "process answers nothing: its callers wait out their own timeouts, a " <>
        "gen_statem's timeouts cannot fire, and a peer that stops answering holds the " <>
        "process for as long as it likes.",
      at: Findings.at_instr(site),
      at_label: "waits with no timeout of its own",
      help: [
        "pass a finite timeout (`:gen_tcp.recv/3`, `:gen_tcp.connect/4`, " <>
          "`:ssl.handshake/3`) and handle `{:error, :timeout}`",
        "or make the socket active and take its data as messages, so the callback " <>
          "never waits on the peer"
      ]
    )
  end

  def finding(:unbounded_wait, [func, site, "global", op, retries, "cluster"]) do
    Findings.new(
      :info,
      "Cluster-wide :global synchronization",
      "#{func} calls :global.#{op} with retries = #{retries}. :global " <>
        "operations serialize across the whole cluster — fine when " <>
        "deliberate, but every caller shares one distributed lock, and " <>
        "partition recovery stalls them all.",
      at: Findings.at_instr(site),
      at_label: "cluster-wide operation",
      help: ["bound `retries` so a partition fails this caller instead of holding it"]
    )
  end

  def finding(:unbounded_wait, [func, site, "global", op, retries, "local"]) do
    Findings.new(
      :info,
      "Local :global lock without a retry bound",
      "#{func} calls :global.#{op} with retries = #{retries} over only the " <>
        "local node. No other node takes part, so a partition cannot stall " <>
        "it, but the caller waits for as long as another process on this " <>
        "node holds the lock.",
      at: Findings.at_instr(site),
      at_label: "lock on this node alone, retried until it is free",
      help: ["bound `retries` so a held lock fails this caller instead of holding it"]
    )
  end

  # "unknown": the node list is not in the bytecode. Reported as the
  # cluster-wide lock it may be, saying it is assumed — as is any list
  # not known to be local or cluster.
  def finding(:unbounded_wait, [func, site, "global", op, retries, _nodes]) do
    Findings.new(
      :info,
      "Cluster-wide :global synchronization",
      "#{func} calls :global.#{op} with retries = #{retries}, and a node " <>
        "list the bytecode does not show, so this assumes it holds the " <>
        "connected nodes. Over the cluster, :global operations serialize " <>
        "across every node — fine when deliberate, but every caller shares " <>
        "one distributed lock, and partition recovery stalls them all.",
      at: Findings.at_instr(site),
      at_label: "assumed cluster-wide: the node list could not be read",
      help: ["bound `retries` so a partition fails this caller instead of holding it"]
    )
  end

  def finding(:partial_noproc_catch, [func, _try, callee, call, guard_end]) do
    Findings.new(
      :warning,
      "Peer call catches :noproc but not :shutdown",
      "#{func} wraps #{Findings.call_name(callee)} in a catch for `{:noproc, _}` — the peer may not " <>
        "exist — but the peer stopping while the call is in flight is the same " <>
        "condition, and it arrives as `{:shutdown, _}` (or `{:normal, _}`), which " <>
        "this catch lets crash the caller.",
      at: Findings.at_site_in_func(call, func),
      to: Findings.at_instr(guard_end),
      # An exit is only ever caught, never rescued: the keyword is known.
      to_block: :guard,
      at_label: "the call and its catch, which takes only :noproc",
      help: [
        "add a clause for `:exit, {:shutdown, _}` (and `{:normal, _}`)",
        "or catch `:exit, reason` and classify it"
      ]
    )
  end

  @impl true
  def evidence(:call_cycle_path, [_a, _b, from_mod, to_mod, witness, how, site]) do
    label =
      case how do
        "tag" -> "cycle edge #{from_mod} → #{to_mod}, inferred from the message tag"
        _ -> "cycle edge #{from_mod} → #{to_mod}"
      end

    Findings.related(label, Findings.at_site_in_func(site, witness, from_mod))
  end

  def evidence(:bottleneck_caller, [caller_mod, _target_mod, witness]) do
    Findings.related("caller #{caller_mod}", Findings.at_func(witness))
  end

  def evidence(:rpc_infinity_caller, [_func, _site, caller]) do
    Findings.related("passes :infinity as the timeout", Findings.at_func(caller))
  end

  defp where("direct", callback), do: "and #{callback} is that callback"
  defp where(_helper, callback), do: "reached directly from the callback #{callback}"

  # What a timeout does when it runs out differs by API: :rpc answers
  # with a value, :erpc raises, a multicall names the node, and a yield
  # has a timed form of its own. The help says the one the call gets.
  @spec rpc_timeout_help(String.t()) :: String.t()
  defp socket_wait(":gen_tcp.connect/3"),
    do: "waits until the operating system gives up on the connect, minutes on Linux"

  defp socket_wait(_api), do: "waits with :infinity"

  defp rpc_timeout_help(variant) when variant in ["rpc", "block_call"],
    do: "pass a timeout (the last argument) and take `{:badrpc, :timeout}` as a result"

  defp rpc_timeout_help("multicall"),
    do:
      "pass a timeout (the last argument); a node that does not answer in time is " <>
        "in the bad nodes of the `{results, bad_nodes}` result"

  defp rpc_timeout_help("erpc"),
    do:
      "pass a timeout (the last argument); when it runs out the call raises " <>
        "`{:erpc, :timeout}`, so rescue `ErlangError` or catch `:error` around it"

  defp rpc_timeout_help("erpc_multicall"),
    do:
      "pass a timeout (the last argument); a node that does not answer in time " <>
        "gives `{:error, {:erpc, :timeout}}` in its place in the results"

  defp rpc_timeout_help(variant) when variant in ["yield", "nb_yield"],
    do:
      "collect the answer with `:rpc.nb_yield/2` and a finite timeout; it " <>
        "returns `:timeout` when the answer has not come"

  defp rpc_timeout_help("erpc_receive"),
    do:
      "pass a timeout to `:erpc.receive_response/2`; when it runs out it raises " <>
        "`{:erpc, :timeout}`, so rescue `ErlangError` or catch `:error` around it"

  # A variant rpc_call does not emit today: the timeout's advice in general.
  defp rpc_timeout_help(_variant),
    do: "pass a timeout (the last argument) and handle the call running out of it"
end
