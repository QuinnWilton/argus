defmodule Argus.Analyses.Failure do
  @moduledoc """
  An error path swallowed, half-caught or ignored.

  - `unhandled_failure(func, site, kind, shape)` — a failure nothing
    takes. `kind` is `rescue` (a catch-all rescue discards the exception:
    the failure surfaces later, far from its cause), `erpc_transport` (a
    rescue around `:erpc.call` unwraps remote exceptions and has no
    clause for transport failures), or the rpc variant `rpc`,
    `multicall` or `erpc` whose result is matched by `shape` `case` with
    no `{:badrpc, _}` clause, or used as a `boolean` where the tuple is
    truthy (for `:erpc`, with no rescue for `{:erpc, :noconnection}`).
  - `unchecked_result(func, site, api, name)` — a result used without
    its failure case: `Task.Supervisor.start_child` discarded, or a
    `Process.whereis` of `name` used without its nil case.
  - `orphan_process(func, site, kind, target)` — a process nothing
    supervises: a bare `spawn` nothing links to or monitors afterwards,
    or an `exit` signal sent to `target` from a callback, past the
    supervisor that owns it. An exit to a process the sending module
    started itself is not one; an exit process points-to resolves to a
    supervisor's child names the child as `target`, and its supervisor
    (`exit_target_owner`) is a related frame.
  - `inconsistent_handling(func, site, callee, belief, agree, deviate, target)` —
    a call site that breaks with the program's own convention for its
    callee: `belief` is `result_checked` (a clear majority of the sites
    match the result; this one discards it) or `exception_guarded` (a
    clear majority wrap the call in a `try` that takes what it raises;
    this one does not). The title says "every other call site" only when
    this one is the sole deviant, and "most call sites" otherwise. `agree` and
    `deviate` are the counts, and the severity is how unlikely the
    deviation is by chance. The population is the callee's sites on the
    same literal `target` (a table, a name) when the site has one, and
    every site of the callee when it does not (`target` empty).
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
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.Specs,
      Argus.Extractors.Generated,
      # Which process an exit signal or a monitor reaches, and whether a
      # supervisor owns it (clientlib/processes.dl, signals.dl).
      Argus.Extractors.PidFlow,
      Argus.Extractors.Supervision,
      # A gen_statem's state functions and data (clientlib/process_statem.dl,
      # and processes.dl in the points-to stage).
      Argus.Extractors.GenStatem
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :unhandled_failure,
        fields: [
          {:func, :symbol, "the function the failure reaches"},
          {:site, :symbol, "the rescue's try, the guarded call, or the rpc call"},
          {:kind, :symbol, "rescue | erpc_transport | rpc | multicall | erpc"},
          {:shape, :symbol,
           "for an rpc variant, case (matched, no clause) or boolean (truthy tuple)"},
          {:span_end, :symbol, "for erpc_transport, the guard's last instruction; else empty"}
        ],
        key: [:func, :site],
        doc: "A failure value or exception that nothing takes."
      },
      %{
        name: :unchecked_result,
        fields: [
          {:func, :symbol, "the function using the result"},
          {:site, :symbol, "instruction ID of the call"},
          {:api, :symbol, "Task.Supervisor.start_child | Process.whereis"},
          {:name, :symbol, "the process name looked up, for Process.whereis"}
        ],
        key: [:func, :site],
        doc: "A result used without its failure case."
      },
      %{
        name: :inconsistent_handling,
        fields: [
          {:func, :symbol, "the function holding the deviant site"},
          {:site, :symbol, "instruction ID of the call"},
          {:callee, :symbol, "the callee whose other sites disagree"},
          {:belief, :symbol, "result_checked | exception_guarded"},
          {:agree, :number, "sites that follow the convention"},
          {:deviate, :number, "sites that break it, this one included"},
          {:target, :symbol,
           "the literal first argument the population shares; empty for all sites"}
        ],
        key: [:func, :site, :belief],
        doc: "A call site that breaks with how the program's other sites treat the same callee."
      },
      %{
        name: :handling_site,
        fields: [
          {:callee, :symbol, "the callee"},
          {:belief, :symbol, "result_checked | exception_guarded"},
          {:site, :symbol, "a call site that follows the convention"},
          {:func, :symbol, "the function it is in"},
          {:guard, :symbol,
           "for exception_guarded, here (a try in its own function) or callers " <>
             "(every way into its function passes one); else empty"},
          {:guard_end, :symbol,
           "for exception_guarded, the guard's last instruction; else empty"},
          {:target, :symbol, "the population's target, as inconsistent_handling"}
        ],
        key: [:callee, :belief, :target, :site],
        evidence: %{of: :inconsistent_handling, on: [:callee, :belief, :target], limit: 3},
        doc: "Sites that follow the convention the deviant one breaks, attached to its finding."
      },
      %{
        name: :orphan_process,
        fields: [
          {:func, :symbol, "the function spawning or sending the exit"},
          {:site, :symbol, "instruction ID of the spawn, or the callback for an exit"},
          {:kind, :symbol, "spawn | exit"},
          {:target, :symbol,
           "the exit target, for an exit: the supervised child's module when " <>
             "points-to resolves it to one"}
        ],
        key: [:func, :site, :kind, :target],
        doc: "A process nothing supervises: a bare spawn, or an exit signal past the supervisor."
      },
      %{
        name: :exit_target_owner,
        fields: [
          {:func, :symbol, "the callback sending the exit"},
          {:target, :symbol, "the supervised child's module"},
          {:sup, :symbol, "the supervisor that owns it"},
          {:sup_site, :symbol, "where the supervisor defines its children"}
        ],
        key: [:func, :target, :sup],
        evidence: %{of: :orphan_process, on: [:func, :target]},
        doc: "The supervisor that owns an exit signal's target, attached to its finding."
      }
    ]
  end

  @impl true
  def finding(:inconsistent_handling, [func, site, callee, belief, agree, deviate, _target]) do
    {agree, deviate} = {String.to_integer(agree), String.to_integer(deviate)}
    total = agree + deviate

    # clear_majority lets a quarter of the population deviate: with more
    # than one deviant, "every other" is not true of this one's peers.
    {others, ending} =
      if deviate == 1, do: {"every other call site", "s"}, else: {"most call sites", ""}

    {title, what, fix} =
      case belief do
        "result_checked" ->
          {"#{Findings.call_name(callee)} result ignored where #{others} check#{ending} it",
           "discards the result of #{Findings.call_name(callee)}, which #{agree} of the #{total} call " <>
             "sites in this program match on", "match on the result as the other sites do"}

        "exception_guarded" ->
          {"#{Findings.call_name(callee)} called bare where #{others} guard#{ending} it",
           "calls #{Findings.call_name(callee)} outside a try, which #{agree} of the #{total} call sites " <>
             "in this program wrap in one", "guard the call as the other sites do"}
      end

    Findings.new(
      deviance_severity(agree, total),
      title,
      "#{func} #{what}. No rule says the callee's failure must be taken; the " <>
        "program's own sites say so, and this one disagrees — the shape of a " <>
        "site written without the convention in mind, or one the convention " <>
        "grew around.",
      at: Findings.at_site_in_func(site, func),
      at_label: "the one site that disagrees",
      help: [fix, "or, if this site is right, the other #{agree} are worth a look"]
    )
  end

  def finding(:unhandled_failure, [func, site, "rescue", _, span_end]) do
    Findings.new(
      :warning,
      "Catch-all rescue swallows exceptions",
      "#{func} takes every exception in a {guard} clause without re-raising, " <>
        "logging, or matching a type. Bugs become silence: the failure surfaces " <>
        "later, far from its cause, with the stacktrace gone.",
      at: Findings.at_site_in_func(site, func),
      to: Findings.at_instr(span_end),
      to_block: :guard,
      at_label: "this {guard} takes everything",
      help: [
        "rescue the specific exceptions this code can handle, and re-raise or log the rest"
      ]
    )
  end

  def finding(:orphan_process, [func, _site, "exit", target]) do
    whom = if target == "dynamic", do: "a process it holds as a value", else: target

    Findings.new(
      :info,
      "Process.exit inside a GenServer callback",
      "#{Findings.call_name(func)} sends an exit signal to #{whom} from inside a callback. " <>
        "This is often deliberate — process-manager handoff, registry " <>
        "name-conflict resolution, an ownership watcher killing dependents — " <>
        "but killing a process imperatively bypasses the supervisor that " <>
        "started it, so it is worth confirming the target is meant to be " <>
        "torn down this way rather than stopped through its own protocol.",
      at: Findings.at_func(func),
      at_label: "sends an exit signal from a callback",
      help: [
        "stop the target through its own protocol (`GenServer.stop/1`, a message) " <>
          "or through its supervisor, if this is not a deliberate teardown"
      ]
    )
  end

  def finding(:unhandled_failure, [func, site, "erpc_transport", _, span_end]) do
    Findings.new(
      :warning,
      ":erpc.call transport failures fall through the rescue",
      "#{func} takes the ErlangError :erpc.call raises in a {guard} and unwraps the " <>
        "`{:exception, _, _}` a remote raise produces, but a node going away " <>
        "raises `{:erpc, :noconnection}` (or `{:erpc, :timeout}`, " <>
        "`{:erpc, :system_limit}`), and the {guard}'s `case` has no clause for " <>
        "it — a CaseClauseError in place of a result.",
      at: Findings.at_site_in_func(site, func),
      to: Findings.at_instr(span_end),
      to_block: :guard,
      at_label: "the call and its {guard}, which has no {:erpc, _} clause",
      help: ["add a clause for `{:erpc, reason}` and return or raise a meaningful error"]
    )
  end

  def finding(:unhandled_failure, [func, site, "erpc", "boolean", _]) do
    Findings.new(
      :warning,
      ":erpc.call in a boolean context with no rescue",
      "#{func} uses the result of :erpc.call as a boolean. A node that went " <>
        "away between the check that chose it and the call raises " <>
        "`{:erpc, :noconnection}` here, and nothing rescues it.",
      at: Findings.at_site_in_func(site, func),
      at_label: "raises on a gone node",
      help: ["rescue ErlangError with `{:erpc, :noconnection}` and treat it as false"]
    )
  end

  def finding(:unhandled_failure, [func, site, variant, "boolean", _]) do
    Findings.new(
      :warning,
      "RPC result used as a boolean",
      "#{func} uses the result of #{Findings.rpc_api(variant)} as a boolean. A node that is " <>
        "gone answers `{:badrpc, :nodedown}` (a timeout `{:badrpc, :timeout}`), " <>
        "and a tuple is truthy: the failure reads as true.",
      at: Findings.at_site_in_func(site, func),
      at_label: "{:badrpc, _} is truthy here",
      help: ["match `{:badrpc, _}` explicitly before treating the result as a boolean"]
    )
  end

  def finding(:unhandled_failure, [func, site, variant, "case", _]) do
    Findings.new(
      :warning,
      "RPC result matched without a {:badrpc, _} clause",
      "#{func} matches the result of #{Findings.rpc_api(variant)} by shape and has no clause " <>
        "for `{:badrpc, reason}` — a node that is down, a timeout, a remote " <>
        "exit — so a cluster failure is a CaseClauseError (or MatchError) " <>
        "instead of an error value.",
      at: Findings.at_site_in_func(site, func),
      at_label: "no {:badrpc, _} clause",
      help: ["add a `{:badrpc, reason} -> {:error, reason}` clause, or move to :erpc and rescue"]
    )
  end

  def finding(:unchecked_result, [func, id, "Task.Supervisor.start_child", _]) do
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

  def finding(:orphan_process, [func, id, "spawn", _]) do
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

  def finding(:unchecked_result, [func, id, "Process.whereis", name]) do
    Findings.new(
      :warning,
      "whereis result used without a nil check",
      "#{func} looks up #{name} with Process.whereis and uses the result " <>
        "without handling nil. The target can die (or not yet be registered) " <>
        "between lookup and use — the classic time-of-check/time-of-use race.",
      at: Findings.at_instr(id),
      at_label: "may be nil here",
      help: ["send to the registered name directly, or match nil explicitly"]
    )
  end

  # Engler's ranking: how many standard deviations the agreeing fraction
  # sits above a coin flip. Seven sites against one is two deviations; the
  # rule's floor of three against one is none, so it stays informational.
  defp deviance_severity(agree, total) do
    z = (agree / total - 0.5) / :math.sqrt(0.25 / total)
    if z >= 2.0, do: :warning, else: :info
  end

  @impl true
  def evidence(:exit_target_owner, [_func, target, sup, sup_site]) do
    Findings.related(
      "#{target} is #{sup}'s child",
      Findings.at_site(sup_site, sup)
    )
  end

  def evidence(:handling_site, [_callee, belief, site, func, guard, guard_end, _target]) do
    case {belief, guard} do
      {"exception_guarded", "callers"} ->
        Findings.related(
          "guarded by a try around every call of its function",
          Findings.at_site_in_func(site, func)
        )

      {"exception_guarded", _here} ->
        Findings.related("guarded by this {guard}", Findings.at_site_in_func(site, func),
          to: Findings.at_instr(guard_end),
          to_block: :guard
        )

      {"result_checked", _} ->
        Findings.related("its result matched here", Findings.at_site_in_func(site, func))
    end
  end
end
