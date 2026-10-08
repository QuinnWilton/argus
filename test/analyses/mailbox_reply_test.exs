defmodule Argus.Analyses.MailboxReplyTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.Reply, as: R
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [
    R.Forgets,
    R.RepliesDirectly,
    R.DefersProperly,
    R.StoresAndForgets,
    R.HandsOff,
    R.StopsWithReply,
    R.CastsAndInfos,
    R.NotAGenServer,
    R.MixedClauses,
    R.KeepsFromAsState,
    R.BuildsBeforeReply,
    R.BuildsBeforeHandoff,
    R.BuildsBeforeUnrelatedWork
  ]

  # Every test reads the same solve of @all: solved once, read-only.
  setup_all do
    %{solved: Memo.analyze(@all, :mailbox)}
  end

  defp results(%{solved: solved}) do
    assert {:ok, r} = solved
    r
  end

  defp never_replies(r),
    do: Rows.where(r, :mailbox, "reply_defect", kind: "dropped_from", drop: [:kind, :tag])

  defp mods(r, "never_replies") do
    r |> never_replies() |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()
  end

  test "only a deferral that keeps no `from` is reported", ctx do
    assert mods(results(ctx), "never_replies") ==
             Enum.sort([
               inspect(R.Forgets),
               # Unrelated work between building the tuple and returning
               # it does not keep `from`.
               inspect(R.BuildsBeforeUnrelatedWork),
               # One clause cannot vouch for another: handle_call/3
               # compiles every clause into one function, so an answer per
               # function lets the correct clauses hide the broken one, and
               # a callback where exactly one clause forgets is the case
               # that occurs. The fact is per return site for this.
               inspect(R.MixedClauses)
             ])

    # Deliberately not reported:
    #   * KeepsFromAsState, BuildsBeforeReply, BuildsBeforeHandoff: using
    #     `from` in or after building the tuple fulfils the contract.
    #   * RepliesDirectly: replying directly promises nothing.
    #   * DefersProperly: storing `from` and replying from another
    #     callback is the point.
    #   * HandsOff: handing `from` to another process is not this
    #     analysis's business.
    #   * StopsWithReply: {:stop, reason, reply, state} answers the caller.
    #   * CastsAndInfos: handle_cast and handle_info return :noreply as a
    #     matter of course.
    #   * NotAGenServer: a handle_call outside a GenServer means nothing.
    #   * StoresAndForgets: storing `from` and never replying hangs its
    #     callers as surely as Forgets, but stating it needs escape
    #     analysis this does not have (`from` leaves through a send, a
    #     spawned closure, an ETS write, any call taking it), and the
    #     heuristic version found nothing across some six thousand modules
    #     before it was removed. Pinned so that its firing is a decision,
    #     not a drift.
  end

  test "a deferral is anchored at its return site, inside the function it names", ctx do
    assert [[mod, func, id]] =
             results(ctx)
             |> never_replies()
             |> Enum.filter(&(hd(&1) == inspect(R.Forgets)))

    assert mod == inspect(R.Forgets)
    assert func =~ "handle_call/3"
    assert String.starts_with?(id, func <> "#"), "the anchor is the return site, not the head"
  end

  describe "the extractor" do
    @describetag flowlog: false

    alias Argus.Extractors.Reply

    defp facts_for(mod) do
      {:beam_file, m, _e, _a, _c, fs} = :beam_disasm.file(:code.which(mod))
      Reply.extract(%{module: m, functions: fs, exports: [], attributes: [], compile_info: []})
    end

    test "records literal return tags per callback" do
      tags =
        facts_for(R.MixedClauses)
        |> Map.get(:callback_return, [])
        |> Enum.filter(fn [_, _, cb, _] -> cb == "handle_call" end)
        |> Enum.map(fn [_, _, _, tag] -> tag end)
        |> Enum.uniq()
        |> Enum.sort()

      assert tags == [":noreply", ":reply"]
    end

    test "a call of arity two or more counts as reading `from`" do
      # Arguments are passed positionally, so `publish(msg, from, state)`
      # compiles to no move at all and mentions {x,1} nowhere. Treating an
      # argument order that happens to line up as evidence of a bug is how a
      # static analysis earns its reputation.
      assert facts_for(R.PassesThrough) |> Map.get(:callback_drops_from, []) == []
    end
  end
end
