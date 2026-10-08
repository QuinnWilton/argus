defmodule Argus.Priors.Questions.PeerAnswersTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.PeerAnswers
  alias Argus.Test.Fixtures.InitRecv
  alias Argus.Test.Fixtures.TimeoutChain.{BlockingCastServer, ServerC}

  defp facts(mods) do
    {:ok, facts} =
      Argus.Pipeline.extract(mods,
        format: :typed,
        extractors:
          Enum.uniq(Argus.Analyses.Blocking.extractors() ++ Argus.Analyses.Startup.extractors())
      )

    facts
  end

  defp subjects,
    do: [BlockingCastServer, ServerC, InitRecv.Waits] |> facts() |> PeerAnswers.subjects()

  test "subjects are every server with a handle_call/3 and every receive with no after" do
    ids = Enum.map(subjects(), & &1.id)
    assert {"server", inspect(ServerC)} in ids
    # `use GenServer` gives a server the default handle_call/3.
    assert {"server", inspect(BlockingCastServer)} in ids
    assert Enum.any?(ids, &match?({"wait", "Argus.Test.Fixtures.InitRecv.Waits:" <> _}, &1))
  end

  test "a server is one request; a module's waits share one" do
    for %{id: {kind, subject}, batch_key: key} <- subjects() do
      case kind do
        "server" -> assert key == {"server", subject}
        "wait" -> assert {"wait", _mod} = key
      end
    end
  end

  test "the state is names: the server's API and what its handle_call calls; the wait's calls" do
    server = Enum.find(subjects(), &(&1.id == {"server", inspect(ServerC)}))
    assert server.state.server == inspect(ServerC)
    assert "lookup/1" in server.state.api
    assert PeerAnswers.state([server]) == server.state

    wait = Enum.find(subjects(), &match?(%{id: {"wait", _}}, &1))
    state = PeerAnswers.state([wait])
    assert [%{function: _, calls: _, literals: _, called_by: _}] = state.functions

    for s <- subjects(), {_k, v} <- s.state, x <- List.wrap(v), is_binary(x) do
      refute x =~ ~r/#\d+$/, "an instruction id leaked into the state: #{x}"
    end
  end

  test "one choice per subject over local, remote and event" do
    server = Enum.find(subjects(), &(&1.id == {"server", inspect(ServerC)}))
    q = PeerAnswers.questions([server])
    assert Map.keys(q) == ["peer__0"]
    assert q["peer__0"].instructions =~ "calls the server `#{inspect(ServerC)}`"
    assert Map.keys(q["peer__0"].criteria) |> Enum.sort() == ~w(event local remote)a
  end

  test "rows carry the likeliest peer and the probability of local" do
    server = Enum.find(subjects(), &(&1.id == {"server", inspect(ServerC)}))
    answer = %{"choice" => "remote", "probabilities" => %{"remote" => 0.6, "local" => 0.3}}

    assert PeerAnswers.rows([server], %{"peer__0" => answer}) ==
             [["server", inspect(ServerC), "remote", "600", "300"]]

    assert PeerAnswers.rows([server], %{"peer__0" => %{"choice" => "x", "probabilities" => %{}}}) ==
             []

    assert PeerAnswers.rows([server], %{}) == []
  end
end
