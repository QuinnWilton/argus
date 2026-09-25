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
  - `orphan_process(func, site, kind, target, callback)` — a process nothing
    supervises: a bare `spawn` nothing links to or monitors afterwards,
    a `start` (`:proc_lib.start`) whose process lives on past its ack,
    or an `exit` signal sent to `target` from a callback, past the
    supervisor that owns it. An exit to a process the sending module
    started itself is not one; an exit process points-to resolves to a
    supervisor's child names the child as `target`, and its supervisor
    (`exit_target_owner`) is a related frame.
  - `inconsistent_handling(func, site, callee, belief, agree, deviate, target, raises, cover, caught)` —
    a call site that breaks with the program's own convention for its
    callee: `belief` is `result_checked` (a clear majority of the sites
    match the result; this one discards it) or `exception_guarded` (a
    clear majority wrap the call in a `try` that takes what it raises;
    this one does not). The title says "every other call site" only when
    this one is the sole deviant, and "most call sites" otherwise. For
    `exception_guarded`, `raises` is the class the call raises and `cover`
    says how the site stands: `none` (no try around it, here or on some
    way in: "called bare"), `try` (inside a try whose handler takes
    `caught`, other classes or nothing) or `callers` (every way in passes
    a try, not always one that takes the class). `agree` and
    `deviate` are the counts, and the severity is how unlikely the
    deviation is by chance. The population is the callee's sites on the
    same literal `target` (a table, a name), or, for a process call on
    the pid a GenServer's or gen_statem's own client function is handed,
    that module's processes (`processes of M`), or, for one on a name a
    local helper builds, what that helper returns (`what M:via/1
    returns`); a site whose target is not known takes no part. Nor does a
    site its arguments say cannot fail: a send to anything but a local
    name, an ETS call that fails only on a missing table made in the
    process that creates it on every path through its init/1 and never
    deletes it, a `lookup_element` of a row that init/1 always seeds and
    nothing removes.
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
      Argus.Extractors.GenStatem,
      # Which named table a process owns and which rows it seeds: an ETS
      # call its arguments say cannot fail takes no part in a belief.
      Argus.Extractors.ETS
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
          {:span_end, :symbol,
           "for erpc_transport, the guard's last instruction; for an rpc answer a " <>
             "wrapper returns, the wrapper the site calls; else empty"}
        ],
        key: [:func, :site],
        doc: "A failure value or exception that nothing takes."
      },
      %{
        name: :rpc_wrapped,
        fields: [
          {:func, :symbol, "the function matching the wrapper's result"},
          {:site, :symbol, "its call of the wrapper"},
          {:rpc, :symbol, "the rpc whose answer the wrapper returns"},
          {:wrapper, :symbol, "the function it calls"}
        ],
        key: [:func, :site, :rpc],
        evidence: %{of: :unhandled_failure, on: [:func, :site], limit: 3},
        doc: "The rpc a wrapper returns the answer of, attached to its caller's finding."
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
           "the literal first argument the population shares, `processes of M` for " <>
             "a client call of M on the pid it is handed, or `what F returns` for a " <>
             "name the local helper F builds"},
          {:raises, :symbol,
           "for exception_guarded, the class the call raises (error | exit | *); else empty"},
          {:cover, :symbol,
           "for exception_guarded, try (a try here takes other classes, or nothing), " <>
             "callers (every way in passes a try, not all of which take the class) " <>
             "or none (no try here, and some way in passes none); else empty"},
          {:caught, :symbol,
           "for cover try, the classes that try takes, space-separated; else empty"}
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
          {:site, :symbol, "instruction ID of the spawn or the exit call"},
          {:kind, :symbol, "spawn | start | exit"},
          {:target, :symbol,
           "the exit target, for an exit: the supervised child's module when " <>
             "points-to resolves it to one"},
          {:callback, :symbol, "for an exit, a callback that runs it; empty for a spawn"}
        ],
        # An exit is one finding per function that makes it, whichever
        # callbacks run it and however many of its clauses do (a
        # supervisor's shutdown kills, then kills harder); a spawn or a
        # start, one per call.
        key: {:kind, %{"exit" => [:func, :target], default: [:func, :site, :target]}},
        earliest: :site,
        doc:
          "A process nothing supervises: a bare spawn, a proc_lib start that outlives " <>
            "its ack, or an exit signal past the supervisor."
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
  def finding(:inconsistent_handling, [func, site, callee, belief, agree, deviate, _target | how]) do
    {agree, deviate} = {String.to_integer(agree), String.to_integer(deviate)}
    total = agree + deviate
    name = Findings.call_name(callee)

    # clear_majority lets a quarter of the population deviate: with more
    # than one deviant, "every other" is not true of this one's peers.
    {others, s, es} =
      if deviate == 1, do: {"every other call site", "s", "es"}, else: {"most call sites", "", ""}

    {title, what, at_label, fix} =
      case {belief, how} do
        {"result_checked", _} ->
          {"#{name} result ignored where #{others} check#{s} it",
           "discards the result of #{name}, which #{agree} of the #{total} call " <>
             "sites in this program match on", "the one site that disagrees",
           "match on the result as the other sites do"}

        {"exception_guarded", [raises, cover, caught]} ->
          guarded_deviant(name, raises, cover, caught, {others, es, agree, total})
      end

    Findings.new(
      deviance_severity(agree, total),
      title,
      "#{func} #{what}. No rule says the callee's failure must be taken; the " <>
        "program's own sites say so, and this one disagrees — the shape of a " <>
        "site written without the convention in mind, or one the convention " <>
        "grew around.",
      at: Findings.at_site_in_func(site, func),
      at_label: at_label,
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

  def finding(:orphan_process, [func, site, "exit", target, callback]) do
    whom = if target == "dynamic", do: "a process it holds as a value", else: target

    where =
      if func == callback,
        do: "from inside a callback",
        else: "in what the callback #{Findings.call_name(callback)} runs"

    Findings.new(
      :info,
      "Process.exit inside a GenServer callback",
      "#{Findings.call_name(func)} sends an exit signal to #{whom} #{where}. " <>
        "This is often deliberate — process-manager handoff, registry " <>
        "name-conflict resolution, an ownership watcher killing dependents — " <>
        "but killing a process imperatively bypasses the supervisor that " <>
        "started it, so it is worth confirming the target is meant to be " <>
        "torn down this way rather than stopped through its own protocol.",
      at: Findings.at_site_in_func(site, func),
      at_label: "sends an exit signal from a callback",
      related:
        if(func == callback,
          do: [],
          else: [Findings.related("a callback that runs it", Findings.at_func(callback))]
        ),
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

  def finding(:unhandled_failure, [func, site, variant, "boolean", wrapper]) do
    Findings.new(
      :warning,
      "RPC result used as a boolean",
      "#{func} uses the result of #{answer(variant, wrapper)} as a boolean. A node that is " <>
        "gone answers `{:badrpc, :nodedown}` (a timeout `{:badrpc, :timeout}`), " <>
        "and a tuple is truthy: the failure reads as true.",
      at: Findings.at_site_in_func(site, func),
      at_label: "{:badrpc, _} is truthy here",
      help: ["match `{:badrpc, _}` explicitly before treating the result as a boolean"]
    )
  end

  def finding(:unhandled_failure, [func, site, variant, "case", wrapper]) do
    Findings.new(
      :warning,
      "RPC result matched without a {:badrpc, _} clause",
      "#{func} matches the result of #{answer(variant, wrapper)} by shape and has no clause " <>
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

  def finding(:orphan_process, [func, id, "spawn", _, _]) do
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

  def finding(:orphan_process, [func, id, "start", _, _]) do
    Findings.new(
      :warning,
      "Process started unwatched past its start",
      "#{func} starts a process with :proc_lib.start — no link, no monitor. The " <>
        "call waits for the process's init_ack and hands back a failed start, but " <>
        "the process goes on after the ack, and from then on nothing observes it: " <>
        "if it crashes, proc_lib logs the crash and nothing restarts it or cleans up " <>
        "after it.",
      at: Findings.at_instr(id),
      at_label: "started here, and watched only until its ack",
      help: [
        "use `:proc_lib.start_link/3` or `:proc_lib.start_monitor/3` so a later crash " <>
          "reaches the caller, or start the process under a supervisor"
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

  # A site the belief finds unguarded, said as it is: outside any try
  # ("none"), inside one whose handler takes other classes or nothing
  # ("try"; `caught` names what it does take), or reached only through
  # callers' tries, not all of which take the class ("callers").
  defp guarded_deviant(name, raises, cover, caught, {others, es, agree, total}) do
    exc = raised(raises)
    peers = "#{agree} of the #{total} call sites in this program catch its #{exc}"

    case cover do
      "try" ->
        takes = caught_classes(caught)

        {"#{name} called in a try that lets its #{exc} through where #{others} catch#{es} it",
         "calls #{name} inside a try that #{takes}; the call raises #{article(exc)}, " <>
           "and #{peers}", "in a try that #{takes}",
         "catch the #{exc} in that try, as the other sites do"}

      "callers" ->
        {"#{name} called with its #{exc} uncaught where #{others} catch#{es} it",
         "calls #{name} outside any try; every way into the function passes one, " <>
           "but not always one that catches #{article(exc)}, and #{peers}",
         "outside any try; its callers' tries miss #{article(exc)}",
         "catch the #{exc} here or in the callers, as the other sites do"}

      "none" ->
        {"#{name} called bare where #{others} catch#{es} its #{exc}",
         "calls #{name} with no try around it, in its own body or on some way into it; " <>
           "#{peers}", "called outside any try",
         "wrap the call in a try that catches the #{exc}, as the other sites do"}

      # A standing the rules do not write: say only what the belief says.
      _unknown ->
        {"#{name} not guarded where #{others} catch#{es} its #{exc}",
         "calls #{name} where no try that catches #{article(exc)} covers it; #{peers}",
         "no try that catches #{article(exc)} covers this call",
         "catch the #{exc} here or in the callers, as the other sites do"}
    end
  end

  # The class a failing call raises, as a reader names it; `*` is a call
  # whose class the extractor does not know.
  defp raised("error"), do: "error"
  defp raised("exit"), do: "exit"
  defp raised("throw"), do: "throw"
  defp raised(_unknown), do: "exception"

  defp article("error"), do: "an error"
  defp article("exit"), do: "an exit"
  defp article("exception"), do: "an exception"
  defp article("throw"), do: "a throw"

  # What the try around a deviant site takes: nothing (an `after`, a
  # handler that raises again) or classes other than the call's.
  defp caught_classes(""), do: "catches nothing"

  defp caught_classes(caught) do
    classes = caught |> String.split(" ", trim: true) |> Enum.map(&":#{&1}")
    "catches only " <> Enum.join(classes, " and ")
  end

  # The rpc whose answer the site matches: its own, or the one a wrapper
  # it calls returns.
  defp answer(variant, ""), do: Findings.rpc_api(variant)

  defp answer(variant, wrapper),
    do: "#{Findings.call_name(wrapper)}, which returns #{Findings.rpc_api(variant)}'s answer,"

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

  def evidence(:rpc_wrapped, [_func, _site, rpc, wrapper]) do
    Findings.related(
      "#{Findings.call_name(wrapper)} returns this rpc's answer",
      Findings.at_instr(rpc)
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
