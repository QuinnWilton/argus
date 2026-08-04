defmodule Argus.Analyses.TimeoutChain do
  @moduledoc """
  GenServer timeout chain detection.

  Detects two dangerous patterns in GenServer callback implementations:

  1. **Timeout chains** — `handle_call/3` callbacks that make synchronous
     calls to other GenServer modules, which in turn make their own sync
     calls. `GenServer.call` defaults to 5000ms, and when handle_call
     makes downstream sync calls, timeouts compose unpredictably: a chain
     A→B→C means A's timeout must accommodate B+C latency.

  2. **Blocking cast handlers** — `handle_cast/2` callbacks that make
     synchronous calls, defeating the async purpose of cast and silently
     blocking the GenServer.

  Requires the OTP extractor for behaviour and sync_call facts.

  ## Output relations

  - `timeout_chain_risk(from, to, depth)` — chain of depth >= 2 through GenServer handle_call callbacks.
  - `blocking_cast_handler(mod, target)` — handle_cast that blocks on a sync call.

  ## Finding severities

  - `timeout_insufficient` — `:error`. The caller's timeout is provably
    smaller than the callee's downstream budget; the outer call can time
    out while the inner work is still legitimately running.
  - `timeout_chain_risk`, `blocking_cast_handler`,
    `infinity_timeout_in_chain` — `:warning`. Composition hazards whose
    impact depends on runtime latency.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :timeout_chain

  @impl true
  def description, do: "GenServer timeout chain and blocking cast handler detection"

  @impl true
  def rules_file, do: "analyses/timeout_chain.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.GenEvent,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Literal,
      # See sync_call_in_init: the `sync_call` rows this analysis chains
      # together are partly derived by clientlib/interprocedural.dl, which
      # needs call_arg and call_arg_forward to resolve a target forwarded
      # through a wrapper.
      Argus.Extractors.CallArgs
    ]

  alias Argus.Findings

  @impl true
  def output_relations do
    [
      %{
        name: :timeout_chain_risk,
        fields: [
          {:from, :symbol, "outermost GenServer module"},
          {:to, :symbol, "innermost GenServer module"},
          {:depth, :number, "chain depth (>= 2)"}
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
      }
    ]
  end

  @impl true
  def finding(:timeout_chain_risk, [from, to, depth]) do
    Findings.new(
      :warning,
      "GenServer call chain of depth #{depth}",
      "A request into #{from} traverses #{depth} synchronous hops, ending at " <>
        "#{to}. GenServer.call's default 5000ms timeout applies per hop, so " <>
        "the deadlines compose unpredictably: a slow leaf times out every " <>
        "caller above it, and each level retries or crashes on its own " <>
        "schedule.",
      at: Findings.at_mfa(from, :handle_call, 3),
      related: [Findings.related("innermost callee", Findings.at_module(to))]
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
end
