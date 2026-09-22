defmodule Argus.Priors.Questions.ProcessRoleTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.ProcessRole
  alias Argus.Test.Fixtures.{FacadeCaller, FacadeHelper, FacadeSupervisor}

  defp facts do
    {:ok, facts} =
      Argus.Pipeline.extract([FacadeSupervisor, FacadeCaller, FacadeHelper],
        format: :typed,
        extractors: [
          Argus.Extractors.ApiCalls,
          Argus.Extractors.OTP,
          Argus.Extractors.Supervision,
          Argus.Extractors.ProcessRegistry
        ]
      )

    facts
  end

  test "subjects are the modules with a call but no callback loop" do
    subjects = ProcessRole.subjects(facts())
    ids = Enum.map(subjects, & &1.id)
    assert ids == [inspect(FacadeHelper)]
    assert Enum.all?(subjects, &(&1.batch_key == &1.id))
  end

  test "the state is the module's shape in names" do
    [subject] = ProcessRole.subjects(facts())
    state = subject.state
    assert state.module == inspect(FacadeHelper)
    assert state.behaviours == []
    assert "child_spec/1" in state.defines
    assert "remember/2" in state.functions_that_message_a_process
    refute "scale/1" in state.functions_that_message_a_process
    assert "GenServer" in state.calls_into_modules
    assert inspect(FacadeCaller) in state.called_from_modules
    assert Enum.sort(state.exported_functions) == ["child_spec/1", "remember/2", "scale/1"]

    for {_k, v} <- state, s <- List.wrap(v), is_binary(s) do
      refute s =~ ~r/#\d+$/, "an instruction id leaked into the state: #{s}"
    end
  end

  test "one role choice and one noul per subject; the noul is the row" do
    subjects = ProcessRole.subjects(facts())
    questions = ProcessRole.questions(subjects)
    assert Map.keys(questions) |> Enum.sort() == ~w(api_messages_a_process__0 role__0)
    assert questions["role__0"].type == "choice"

    assert Map.keys(questions["role__0"].criteria) |> Enum.sort() ==
             ~w(mixed other process_facade process_impl pure_helper supervisor)a

    assert ProcessRole.rows(subjects, %{"api_messages_a_process__0" => %{"noul" => 0.12}}) ==
             [[inspect(FacadeHelper), "120"]]

    assert ProcessRole.rows(subjects, %{"role__0" => %{"choice" => "pure_helper"}}) == []
  end
end
