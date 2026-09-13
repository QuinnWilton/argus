defmodule Argus.Analyses.ShutdownSafety do
  @moduledoc """
  Cleanup in `terminate/2` that will not run when it matters.

  Another contract nobody writes down. Putting cleanup in `terminate/2`
  looks like saying "run this on the way out". OTP's actual rule is
  narrower, and the gap is silent:

  `terminate/2` runs when a callback returns `{:stop, ...}`, or raises. On a
  **supervisor shutdown** — which is how processes normally stop, and the
  case the cleanup was written for — the parent sends an exit signal, and a
  process that is not trapping exits simply dies. `terminate/2` is never
  called, nothing is logged, and the buffer is not flushed.

  This is documented `GenServer` behaviour and still one of the most
  reliably-made mistakes on the BEAM, because the code reads correctly and
  the tests pass: a test calling `GenServer.stop/1` exercises the path that
  *does* run `terminate`, so the one path that matters in production is the
  one never exercised.

  A second obligation applies once you are trapping: `terminate/2` must
  finish inside the child's shutdown timeout (5000 ms by default) or the
  supervisor brutal-kills it and the cleanup is truncated anyway.

  ## Scope

  Writes only, and not logging. A `terminate/2` that logs "shutting down"
  loses nothing when skipped; one that flushes a buffer, releases a lease,
  or tells another system it is going away loses something real. That
  distinction comes from the `mode` dimension in `Argus.Purity.Effects` —
  the same one that keeps config reads out of the transaction analysis.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :shutdown_safety

  @impl true
  def description, do: "Cleanup in terminate/2 that a supervisor shutdown will skip"

  @impl true
  def rules_file, do: "analyses/shutdown_safety.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Purity,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ErrorHandling
    ]

  @fields [
    {:mod, :symbol, "the module"},
    {:behaviour, :symbol, "the behaviour providing terminate/2"},
    {:category, :symbol, "the kind of cleanup"},
    {:api, :symbol, "the call performing it"},
    {:via, :symbol, "the function performing it"}
  ]

  @impl true
  def output_relations do
    [
      %{
        name: :cleanup_never_runs,
        fields: @fields,
        key: [:mod, :category, :api],
        doc: "terminate/2 performs cleanup, but the process does not trap exits."
      },
      %{
        name: :cleanup_unclear,
        fields: [
          {:mod, :symbol, "the module"},
          {:behaviour, :symbol, "the behaviour providing terminate/2"},
          {:api, :symbol, "an unclassified call it makes"},
          {:via, :symbol, "the function making it"}
        ],
        key: [:mod],
        doc: "terminate/2 does work the effect model cannot classify, and will be skipped."
      },
      %{
        name: :terminate_may_be_truncated,
        fields: @fields,
        key: [:mod, :category, :api],
        doc: "terminate/2 performs unbounded work inside the shutdown timeout."
      }
    ]
  end

  @impl true
  def finding(:cleanup_never_runs, [mod, behaviour, category, api, via]) do
    Findings.new(
      :error,
      "#{mod} cleans up in terminate/2 but never traps exits",
      "#{via} calls #{api} — #{phrase(category)} — from #{mod}'s terminate/2. " <>
        "A #{behaviour} only runs terminate/2 when a callback returns {:stop, ...} " <>
        "or raises. On a supervisor shutdown the parent sends an exit signal, and " <>
        "a process that is not trapping exits dies immediately: terminate/2 is " <>
        "never called and this cleanup is silently skipped. " <>
        "That is the normal way processes stop, so it is the case the cleanup was " <>
        "presumably written for. Tests miss it because GenServer.stop/1 exercises " <>
        "the path that does run terminate. " <>
        "Add Process.flag(:trap_exit, true) in init/1 — and then make sure the " <>
        "work finishes inside the child's shutdown timeout.",
      at: Findings.at_func("#{mod}:terminate/2")
    )
  end

  def finding(:cleanup_unclear, [mod, behaviour, api, via]) do
    Findings.new(
      :warning,
      "#{mod}'s terminate/2 does work that a supervisor shutdown will skip",
      "#{mod} does not trap exits, so a #{behaviour} shutdown from its supervisor " <>
        "kills it outright and terminate/2 never runs. #{via} calls #{api}, which " <>
        "the effect model cannot classify — so this cannot say WHAT is skipped, only " <>
        "that terminate/2 does more than log and none of it will happen on the normal " <>
        "stop path. If that call releases a lease, closes a session or flushes a " <>
        "buffer, it is silently not happening in production. " <>
        "Add Process.flag(:trap_exit, true) in init/1, or move the cleanup somewhere " <>
        "it will actually run.",
      at: Findings.at_func("#{mod}:terminate/2")
    )
  end

  def finding(:terminate_may_be_truncated, [mod, behaviour, category, api, via]) do
    Findings.new(
      :warning,
      "#{mod}'s terminate/2 does unbounded work inside the shutdown timeout",
      "#{via} calls #{api} — #{phrase(category)} — from #{mod}'s terminate/2. " <>
        "The module traps exits, so the callback is reached, but a #{behaviour} " <>
        "child gets only its shutdown timeout (5000ms unless the child spec says " <>
        "otherwise) before the supervisor brutal-kills it. A call with no bound of " <>
        "its own can exceed that, and the cleanup is truncated at whatever point it " <>
        "had reached — often worse than not starting. Bound the call explicitly, or " <>
        "raise the child's shutdown timeout to cover it.",
      at: Findings.at_func("#{mod}:terminate/2")
    )
  end

  defp phrase("io"), do: "file I/O"
  defp phrase("network"), do: "network I/O"
  defp phrase("ets"), do: "a shared-table write"
  defp phrase("process"), do: "a process operation"
  defp phrase("port"), do: "a port or OS operation"
  defp phrase("node"), do: "a distribution operation"
  defp phrase(other), do: other
end
