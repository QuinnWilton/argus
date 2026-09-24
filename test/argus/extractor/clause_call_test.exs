defmodule Argus.Extractor.ClauseCallTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.ClauseCall.{Router, Server}

  # callee function name => the tags the call to it serves, keyed by
  # each call site's own remote_call row.
  setup_all do
    {:ok, facts} =
      Argus.Pipeline.extract([Server, Router], extractors: [Argus.Extractors.ClauseCall])

    callee_at =
      for [id, _caller, "Argus.Test.Fixtures.ClauseCall.Dest", func, _arity] <-
            Map.fetch!(facts, :remote_call),
          into: %{},
          do: {id, func}

    tags =
      facts
      |> Map.get(:clause_call, [])
      |> Enum.flat_map(fn [id, _func, tag] ->
        case Map.fetch(callee_at, id) do
          {:ok, callee} -> [{callee, tag}]
          :error -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {callee, tags} -> {callee, Enum.sort(tags)} end)

    %{tags: tags}
  end

  test "a call in a clause headed by a tuple serves that tuple's tag", %{tags: tags} do
    assert tags["tuple_tag"] == [":tuple_tag"]
  end

  test "a call in a clause headed by an atom serves that atom", %{tags: tags} do
    assert tags["bare_atom"] == [":bare_atom"]
  end

  test "a clause guarded over several tags serves each of them", %{tags: tags} do
    assert tags["either"] == [":left", ":right"]
  end

  test "two clauses of one tag, told apart by the state, both serve it", %{tags: tags} do
    assert tags["ready"] == [":twice"]
    assert tags["not_ready"] == [":twice"]
  end

  test "a case on the request in the body refines like a clause head", %{tags: tags} do
    assert tags["cased"] == [":cased"]
  end

  test "a call some path reaches with no tag established has no row", %{tags: tags} do
    refute Map.has_key?(tags, "fallback")
  end

  test "a plain function's clauses are told apart by their first argument", %{tags: tags} do
    assert tags["local"] == [":local"]
    assert tags["remote"] == [":remote"]
  end

  test "a call a helper makes has no site in handle_call/3", %{tags: tags} do
    refute Map.has_key?(tags, "helper")
  end

  describe "skipped_on_shutdown" do
    alias Argus.Test.Fixtures.SiblingGuard, as: G

    defp skipped_callees(mod) do
      {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [Argus.Extractors.ClauseCall])
      skipped = facts |> Map.get(:skipped_on_shutdown, []) |> Enum.map(&hd/1) |> MapSet.new()

      for [id, _caller, callee_mod, func, _arity] <- Map.fetch!(facts, :remote_call),
          MapSet.member?(skipped, id),
          do: {callee_mod, func}
    end

    test "a call after the clause that takes :shutdown is skipped on shutdown" do
      skipped = skipped_callees(G.ShutdownClauseFirst)

      assert {"Argus.Test.Fixtures.SiblingGuard.Directory", "unregister"} in skipped
      # Of the two File.close calls, the :shutdown clause's own runs.
      assert Enum.count(skipped, &(&1 == {"File", "close"})) == 1
    end

    test "a call in the clause every other reason takes runs on shutdown" do
      assert skipped_callees(G.OtherReasonFirst) |> Enum.filter(&(elem(&1, 1) == "unregister")) ==
               []
    end
  end
end
