defmodule Argus.Analyses.MailboxReplyTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

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

  defp named?(list, fragment), do: Enum.any?(list, &String.contains?(&1, fragment))

  describe "detection" do
    test "unrelated work between tuple construction and return does not keep from", ctx do
      assert named?(mods(results(ctx), "never_replies"), "BuildsBeforeUnrelatedWork")
    end

    test "deferring without keeping `from` is reported", ctx do
      assert [[mod, func, id]] =
               results(ctx)
               |> never_replies()
               |> Enum.filter(&(hd(&1) =~ "Reply.Forgets"))

      assert mod =~ "Reply.Forgets"
      assert func =~ "handle_call/3"
      assert id =~ "handle_call/3#", "should anchor the return site, not the function"
    end

    test "the return site is anchored, not the clause's first instruction", ctx do
      assert [[_mod, func, id]] =
               results(ctx)
               |> never_replies()
               |> Enum.filter(&(hd(&1) =~ "Reply.Forgets"))

      assert String.starts_with?(id, func <> "#"),
             "the anchor must sit inside the function it names"
    end
  end

  describe "one clause cannot vouch for another" do
    # The whole reason the fact is per return site. handle_call/3 compiles
    # every clause into one function, so a function-level answer lets the
    # correct clause hide the broken one — and a multi-clause callback where
    # exactly one clause forgets is the case that actually occurs.
    test "a broken clause is found alongside correct siblings", ctx do
      assert named?(mods(results(ctx), "never_replies"), "MixedClauses"),
             "the forgetful clause was masked by its well-behaved siblings"
    end
  end

  describe "what is deliberately not reported" do
    test "using from in or after tuple construction fulfills the reply contract", ctx do
      r = results(ctx)
      refute named?(mods(r, "never_replies"), "KeepsFromAsState")
      refute named?(mods(r, "never_replies"), "BuildsBeforeReply")
      refute named?(mods(r, "never_replies"), "BuildsBeforeHandoff")
    end

    test "replying directly promises nothing", ctx do
      refute named?(mods(results(ctx), "never_replies"), "RepliesDirectly")
    end

    test "storing `from` and replying from another callback is the point", ctx do
      r = results(ctx)
      refute named?(mods(r, "never_replies"), "DefersProperly")
    end

    test "handing `from` to another process is not this analysis's business", ctx do
      r = results(ctx)
      refute named?(mods(r, "never_replies"), "HandsOff")
    end

    test "{:stop, reason, reply, state} answers the caller", ctx do
      refute named?(mods(results(ctx), "never_replies"), "StopsWithReply")
    end

    test "handle_cast and handle_info return :noreply as a matter of course", ctx do
      r = results(ctx)
      refute named?(mods(r, "never_replies"), "CastsAndInfos")
    end

    test "a handle_call outside a GenServer means nothing", ctx do
      refute named?(mods(results(ctx), "never_replies"), "NotAGenServer")
    end

    test "storing `from` and never replying is a real bug this does not claim", ctx do
      # StoresAndForgets hangs its callers exactly as surely as Forgets
      # does. Stating it precisely needs escape analysis this does not have
      # — `from` leaves through a send, a spawned closure, an ETS write, or
      # any call that happens to take it as an argument — and the heuristic
      # version found nothing across roughly six thousand modules before it
      # was removed. Pinned so that if it ever starts firing, that is a
      # decision someone made rather than a drift nobody noticed.
      refute named?(mods(results(ctx), "never_replies"), "StoresAndForgets")
    end
  end

  describe "the extractor" do
    @describetag souffle: false

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
