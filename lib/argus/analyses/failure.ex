defmodule Argus.Analyses.Failure do
  @moduledoc """
  An error path swallowed, half-caught or ignored.

  - `swallowed_error(func)` — a catch-all rescue that discards the
    exception: the failure surfaces later, far from its cause.
  - `rpc_result_unhandled(func, site, variant, shape)` — an `:rpc` result
    matched by shape with no `{:badrpc, _}` clause, or used as a boolean
    where the tuple is truthy; an `:erpc` result used as a boolean with
    no rescue for `{:erpc, :noconnection}`.
  - `erpc_transport_unhandled(func, site)` — a rescue around `:erpc.call`
    that unwraps remote exceptions and has no clause for transport
    failures.
  - `unchecked_start_child(func, id)` — `Task.Supervisor.start_child`'s
    result discarded.
  - `whereis_race(id, func, name)` — a `Process.whereis` result used
    without its nil case.
  - `unlinked_spawn(func, id)` — a bare `spawn`: no link, no monitor,
    nothing observes a crash.
  - `exit_in_callback(func, target)` — an exit signal sent from a
    callback, past the supervisor that owns the target.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :failure

  @impl true
  def description, do: "error paths swallowed, half-caught or ignored"

  @impl true
  def rules_file, do: "analyses/failure.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.CallArgs,
      Argus.Extractors.ProcessRegistry
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :swallowed_error,
        fields: [{:func, :symbol, "function with bare rescue"}],
        doc: "Catch-all rescue that silently discards exceptions."
      },
      %{
        name: :exit_in_callback,
        fields: [
          {:func, :symbol, "callback function"},
          {:target, :symbol, "exit target"}
        ],
        doc: "Explicit Process.exit/2 inside GenServer callback."
      },
      %{
        name: :erpc_transport_unhandled,
        fields: [
          {:func, :symbol, "function calling :erpc.call"},
          {:site, :symbol, "the try"}
        ],
        doc:
          "A rescue around :erpc.call unwraps remote exceptions but has no clause for transport failures."
      },
      %{
        name: :rpc_result_unhandled,
        fields: [
          {:func, :symbol, "function making the rpc"},
          {:site, :symbol, "the rpc call"},
          {:variant, :symbol, "rpc | multicall | erpc"},
          {:shape, :symbol, "'case' (matched by shape, no clause) or 'boolean' (truthy tuple)"}
        ],
        key: [:func, :site],
        doc: "An rpc result whose failure value is not handled."
      },
      %{
        name: :unchecked_start_child,
        fields: [
          {:func, :symbol, "function containing the start_child call"},
          {:id, :symbol, "instruction ID of the start_child call"}
        ],
        doc: "Task.Supervisor.start_child result discarded without error handling."
      },
      %{
        name: :unlinked_spawn,
        fields: [
          {:func, :symbol, "function containing the spawn"},
          {:id, :symbol, "instruction ID of the spawn call"}
        ],
        doc: "Bare erlang:spawn call without link or monitor."
      },
      %{
        name: :whereis_race,
        fields: [
          {:id, :symbol, "instruction ID of the whereis call"},
          {:func, :symbol, "function calling whereis"},
          {:name, :symbol, "process name"}
        ],
        doc: "Process.whereis without nil check (TOCTOU risk)."
      }
    ]
  end

  @impl true
  def finding(:swallowed_error, [func]) do
    Findings.new(
      :warning,
      "Catch-all rescue swallows exceptions",
      "#{func} rescues every exception without re-raising, logging, or " <>
        "matching specific types. Bugs become silence: the failure surfaces " <>
        "later, far from its cause, with the stacktrace gone. Rescue the " <>
        "specific exceptions you can actually handle.",
      at: Findings.at_func(func)
    )
  end

  def finding(:exit_in_callback, [func, target]) do
    Findings.new(
      :info,
      "Process.exit inside a GenServer callback",
      "#{func} sends an exit signal to #{target} from inside a callback. " <>
        "This is often deliberate — process-manager handoff, registry " <>
        "name-conflict resolution, an ownership watcher killing dependents — " <>
        "but killing a process imperatively bypasses the supervisor that " <>
        "started it, so it is worth confirming the target is meant to be " <>
        "torn down this way rather than stopped through its own protocol.",
      at: Findings.at_func(func)
    )
  end

  def finding(:erpc_transport_unhandled, [func, site]) do
    Findings.new(
      :warning,
      ":erpc.call transport failures fall through the rescue",
      "#{func} rescues the ErlangError :erpc.call raises and unwraps the " <>
        "`{:exception, _, _}` a remote raise produces, but a node going away " <>
        "raises `{:erpc, :noconnection}` (or `{:erpc, :timeout}`, " <>
        "`{:erpc, :system_limit}`), and the rescue's `case` has no clause for " <>
        "it — a CaseClauseError in place of a result.",
      at: Findings.at_site(site, func),
      at_label: "rescue without an {:erpc, _} clause",
      help: ["add a clause for `{:erpc, reason}` and return or raise a meaningful error"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, "erpc", "boolean"]) do
    Findings.new(
      :warning,
      ":erpc.call in a boolean context with no rescue",
      "#{func} uses the result of :erpc.call as a boolean. A node that went " <>
        "away between the check that chose it and the call raises " <>
        "`{:erpc, :noconnection}` here, and nothing rescues it.",
      at: Findings.at_site(site, func),
      at_label: "raises on a gone node",
      help: ["rescue ErlangError with `{:erpc, :noconnection}` and treat it as false"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, variant, "boolean"]) do
    Findings.new(
      :warning,
      "RPC result used as a boolean",
      "#{func} uses the result of :rpc.#{variant} as a boolean. A node that is " <>
        "gone answers `{:badrpc, :nodedown}` (a timeout `{:badrpc, :timeout}`), " <>
        "and a tuple is truthy: the failure reads as true.",
      at: Findings.at_site(site, func),
      at_label: "{:badrpc, _} is truthy here",
      help: ["match `{:badrpc, _}` explicitly before treating the result as a boolean"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, variant, _shape]) do
    Findings.new(
      :warning,
      "RPC result matched without a {:badrpc, _} clause",
      "#{func} matches the result of :rpc.#{variant} by shape and has no clause " <>
        "for `{:badrpc, reason}` — a node that is down, a timeout, a remote " <>
        "exit — so a cluster failure is a CaseClauseError (or MatchError) " <>
        "instead of an error value.",
      at: Findings.at_site(site, func),
      at_label: "no {:badrpc, _} clause",
      help: ["add a `{:badrpc, reason} -> {:error, reason}` clause, or move to :erpc and rescue"]
    )
  end

  def finding(:unchecked_start_child, [func, id]) do
    Findings.new(
      :warning,
      "start_child result not checked",
      "#{func} discards the result of Task.Supervisor.start_child. A " <>
        "{:error, reason} return — supervisor at max_children, not yet " <>
        "started, bad child spec — is silently ignored, so failed launches " <>
        "look exactly like successful ones.",
      at: Findings.at_instr(id),
      at_label: "start_child result discarded here",
      help: [
        "match on the result — `{:ok, pid} = Task.Supervisor.start_child(...)` " <>
          "at minimum, or handle `{:error, reason}` explicitly"
      ]
    )
  end

  def finding(:unlinked_spawn, [func, id]) do
    Findings.new(
      :warning,
      "Unlinked process spawned",
      "#{func} spawns a process with bare spawn — no link, no monitor. If the " <>
        "process crashes, nothing observes it: no restart, no log, no cleanup.",
      at: Findings.at_instr(id),
      at_label: "spawned here",
      help: [
        "use `spawn_link/1,3` or `spawn_monitor/1,3` so crashes propagate, " <>
          "or start the process under a `Task.Supervisor`"
      ]
    )
  end

  def finding(:whereis_race, [id, func, name]) do
    Findings.new(
      :warning,
      "whereis result used without a nil check",
      "#{func} looks up #{name} with Process.whereis and uses the result " <>
        "without handling nil. The target can die (or not yet be registered) " <>
        "between lookup and use — the classic time-of-check/time-of-use race. " <>
        "Send to the registered name directly, or handle nil explicitly.",
      at: Findings.at_instr(id)
    )
  end
end
