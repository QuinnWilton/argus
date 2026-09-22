defmodule Argus.Priors.Questions.ReadsTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.Reads
  alias Argus.Test.Fixtures.RequestSurface
  alias Argus.Test.Fixtures.Taint

  defp facts(mods) do
    {:ok, facts} =
      Argus.Pipeline.extract(mods,
        format: :typed,
        extractors: [Argus.Extractors.ApiCalls, Argus.Extractors.OTP]
      )

    facts
  end

  test "subjects are the sink-holding functions that are not request entries" do
    subjects =
      Reads.subjects(
        facts([
          Taint.Store,
          Taint.StoreSourcedPlug,
          Taint.StoreSourcedAdjacent,
          Taint.StoreSourcedWorker,
          RequestSurface.SafeCallback
        ])
      )

    ids = Enum.map(subjects, & &1.id)
    assert "#{inspect(Taint.StoreSourcedAdjacent)}:convert/1" in ids
    assert "#{inspect(Taint.StoreSourcedWorker)}:level_two/1" in ids
    # The plug's sink sits in call/2, a request entry: direct, no question.
    refute Enum.any?(ids, &String.contains?(&1, "StoreSourcedPlug"))
    # to_existing_atom is not a sink.
    refute Enum.any?(ids, &String.contains?(&1, "SafeCallback"))
    assert Enum.all?(subjects, &(&1.batch_key == &1.state.module))
  end

  test "the state is names: the module, its behaviours and functions, the calls and literals" do
    [subject] =
      facts([Taint.Store, Taint.StoreSourcedAdjacent])
      |> Reads.subjects()
      |> Enum.filter(&(&1.id =~ "convert"))

    assert subject.state.module == inspect(Taint.StoreSourcedAdjacent)
    assert subject.state.module_behaviours == ["Phoenix.LiveView"]
    assert subject.state.function == "convert/1"
    assert subject.state.exported
    assert "handle_params/3" in subject.state.sibling_functions
    assert Enum.any?(subject.state.calls, &(&1 =~ "binary_to_atom"))
    refute Map.has_key?(subject.state, :called_by)

    for {_k, v} <- subject.state, s <- List.wrap(v), is_binary(s) do
      refute s =~ ~r/#\d+$/, "an instruction id leaked into the state: #{s}"
    end
  end

  test "the shared state lists every asked function under the module" do
    subjects = facts([Taint.Store, Taint.StoreSourcedWorker]) |> Reads.subjects()
    state = Reads.state(subjects)
    assert state.module == inspect(Taint.StoreSourcedWorker)
    assert Enum.map(state.functions, & &1.function) == ["level_two/1"]
    assert Enum.all?(state.functions, &Map.has_key?(&1, :calls))
  end

  test "one choice and two nouls per subject; the choice names the function" do
    subjects = facts([Taint.Store, Taint.StoreSourcedWorker]) |> Reads.subjects()
    questions = Reads.questions(subjects)
    assert Map.keys(questions) |> Enum.sort() == ~w(origin__0 reads_request__0 reads_storage__0)
    assert questions["origin__0"].instructions =~ "`level_two/1`"
    assert questions["origin__0"].instructions =~ "do not count"

    assert Map.keys(questions["origin__0"].criteria) |> Enum.sort() ==
             ~w(config constant internal passthrough request storage)a
  end

  test "rows carry the chosen source and its probability; unknown sources yield none" do
    subjects = facts([Taint.Store, Taint.StoreSourcedWorker]) |> Reads.subjects()
    [%{id: func}] = subjects

    assert Reads.rows(subjects, %{
             "origin__0" => %{"choice" => "storage", "probabilities" => %{"storage" => 0.87}}
           }) ==
             [[func, "storage", "870"]]

    assert Reads.rows(subjects, %{"origin__0" => %{"choice" => "banana", "probabilities" => %{}}}) ==
             []

    assert Reads.rows(subjects, %{}) == []
  end
end
