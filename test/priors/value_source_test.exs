defmodule Argus.Priors.Questions.ValueSourceTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.ValueSource
  alias Argus.Test.Fixtures.{AtomBounds, AtomSources, CodeExecution, UnsafeDeserialization}
  alias Argus.Test.Fixtures.Taint

  defp facts(mods) do
    {:ok, facts} =
      Argus.Pipeline.extract(mods,
        format: :typed,
        extractors: Argus.Analyses.UnsafeInput.extractors()
      )

    facts
  end

  defp ids(subjects), do: Enum.map(subjects, fn %{id: {func, sink}} -> {short(func), sink} end)

  defp short(func), do: func |> String.split(":") |> List.last()

  test "subjects are the functions holding an unbounded sink, one per kind of sink" do
    ids =
      [AtomSources, UnsafeDeserialization, CodeExecution, AtomBounds]
      |> facts()
      |> ValueSource.subjects()
      |> ids()

    assert {"input/1", "atom"} in ids
    assert {"-keys/1-fun-0-/1", "atom"} in ids
    assert {"decode_unsafe/1", "deserialization"} in ids
    assert {"eval/1", "code"} in ids
    # A bounded atom is no sink, and nothing is asked of it.
    refute {"phrase/1", "atom"} in ids
    refute {"suffixed/1", "atom"} in ids
    # A macro makes its atom at compile time, of the code that uses it.
    refute {"MACRO-field/2", "atom"} in ids
    # The unbounded twin beside it is asked.
    assert {"named/1", "atom"} in ids
  end

  test "a request entry's sink is the request's, not asked" do
    ids = [Taint.StoreSourcedPlug, Taint.Store] |> facts() |> ValueSource.subjects() |> ids()
    refute Enum.any?(ids, fn {func, _} -> func == "call/2" end)
  end

  test "the state is names: the module, its functions, the call, what it calls and who calls it" do
    subjects = [AtomSources] |> facts() |> ValueSource.subjects()

    closure =
      Enum.find(subjects, &match?(%{id: {_, "atom"}, state: %{function: "a fun in keys/1"}}, &1))

    assert closure, "a closure is shown as the function it is written in"

    name = Enum.find(subjects, &(&1.state.function == "name/1"))
    assert name.state.module == inspect(AtomSources)
    assert name.state.call == "`String.to_atom`"
    assert "default_name/0" in name.state.exported_functions
    assert "#{inspect(AtomSources)}.default_name/0" in name.state.called_by

    for s <- subjects, {_k, v} <- s.state, x <- List.wrap(v), is_binary(x) do
      refute x =~ ~r/#\d+$/, "an instruction id leaked into the state: #{x}"
    end
  end

  test "the shared state lists every asked function of the module" do
    subjects = [AtomSources] |> facts() |> ValueSource.subjects()
    state = ValueSource.state(subjects)
    assert state.module == inspect(AtomSources)
    assert length(state.functions) == length(subjects)
    assert Enum.all?(state.functions, &Map.has_key?(&1, :called_by))
    refute Enum.any?(state.functions, &Map.has_key?(&1, :sink))
  end

  test "one choice per subject, asking what the value is, by kind of sink" do
    all = [UnsafeDeserialization, CodeExecution] |> facts() |> ValueSource.subjects()

    subjects = [
      Enum.find(all, &match?(%{id: {_, "deserialization"}}, &1)),
      Enum.find(all, &match?(%{id: {_, "code"}}, &1))
    ]

    questions = ValueSource.questions(subjects)
    assert Map.keys(questions) |> Enum.sort() == ~w(source__0 source__1)

    assert Map.keys(questions["source__0"].criteria) |> Enum.sort() ==
             ~w(cluster code configured operator outside stored)a

    texts = Enum.map(Map.values(questions), & &1.instructions)
    assert Enum.any?(texts, &(&1 =~ "what are the bytes that `:erlang.binary_to_term` decodes"))
    assert Enum.any?(texts, &(&1 =~ "what is the command or code that"))
  end

  test "rows carry the likeliest kind and the mass that is not outside data" do
    subjects = [AtomSources] |> facts() |> ValueSource.subjects()
    [first | _] = subjects
    {func, sink} = first.id

    answer = %{
      "choice" => "configured",
      "probabilities" => %{
        "configured" => 0.6,
        "code" => 0.25,
        "stored" => 0.05,
        "outside" => 0.1
      }
    }

    assert [[^func, ^sink, "configured", "600", "900"]] =
             subjects |> Enum.take(1) |> ValueSource.rows(%{"source__0" => answer})

    assert ValueSource.rows(Enum.take(subjects, 1), %{
             "source__0" => %{"choice" => "banana", "probabilities" => %{}}
           }) == []

    assert ValueSource.rows(Enum.take(subjects, 1), %{}) == []
  end
end
