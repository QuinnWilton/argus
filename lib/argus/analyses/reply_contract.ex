defmodule Argus.Analyses.ReplyContract do
  @moduledoc """
  A deferred reply that can never be sent.

  `handle_call/3` may answer immediately with `{:reply, value, state}`, or
  defer: return `{:noreply, state}` and call `GenServer.reply/2` later. The
  second is a promise, and the only thing that can discharge it is the
  `from` term the callback was handed — an opaque `{pid, tag}` that exists
  nowhere else in the system.

  A `handle_call/3` that defers without keeping `from` has promised
  something it cannot deliver. No later event fixes it.

  ## Why this needs an analysis

  Not because the mistake is subtle, but because of where it surfaces. The
  process that got it wrong is fine — it returned a valid value and went
  back to its loop. The failure appears five seconds later, in a different
  process, in a different module:

      ** (exit) exited in: GenServer.call(pid, :thing, 5000)
           ** (EXIT) time out

  Nothing in that message names the clause that failed to reply. Worse,
  under load it is indistinguishable from overload, which sends people to
  tune pool sizes and mailbox depths for a bug that has nothing to do with
  either.

  ## Precision

  Deliberately a floor rather than a census. Retaining `from` is recorded
  per function, not per clause, so a `handle_call/3` whose other clauses
  defer correctly mentions the register and every clause in it goes
  unreported. Reporting is therefore rare and each report is strong.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :reply_contract

  @impl true
  def description, do: "handle_call clauses that defer a reply they cannot send"

  @impl true
  def rules_file, do: "analyses/reply_contract.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Reply, Argus.Extractors.OTP, Argus.Extractors.ApiCalls]

  @fields [
    {:mod, :symbol, "the module"},
    {:func, :symbol, "the handle_call/3 function"},
    {:id, :symbol, "the return site"}
  ]

  @impl true
  def output_relations do
    [
      %{
        name: :never_replies,
        fields: @fields,
        key: [:mod, :func, :id],
        doc: "handle_call returns {:noreply, _} without keeping `from`."
      }
    ]
  end

  @impl true
  def finding(:never_replies, [mod, func, id]) do
    Findings.new(
      :error,
      "#{mod} defers a reply it cannot send",
      "#{func} returns {:noreply, _}, which promises a later GenServer.reply/2, " <>
        "but never reads its `from` argument. `from` is the only handle on the " <>
        "caller — an opaque {pid, tag} that exists nowhere else — so nothing in " <>
        "the system can discharge that promise. " <>
        "Every caller reaching this clause blocks for its full GenServer.call/3 " <>
        "timeout and then exits. The exit is raised in the caller, in another " <>
        "module, with a message that names neither this function nor this clause, " <>
        "and under load it is indistinguishable from overload. " <>
        "Either reply directly with {:reply, value, state}, or store `from` in " <>
        "state and reply when the work completes.",
      at: Findings.at_instr(id)
    )
  end
end
