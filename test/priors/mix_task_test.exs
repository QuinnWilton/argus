defmodule Mix.Tasks.Argus.PriorsTest do
  use ExUnit.Case

  alias Argus.Priors.Cache
  alias Mix.Tasks.Argus.Priors, as: PriorsTask

  @moduletag :tmp_dir

  @generation %{
    model: "jev-test",
    question: "Elixir.Argus.Priors.Questions.Sensitivity",
    prompt_version: 1
  }

  setup %{tmp_dir: dir} do
    previous = System.get_env("ARGUS_PRIORS_DIR")
    System.put_env("ARGUS_PRIORS_DIR", dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("ARGUS_PRIORS_DIR", previous),
        else: System.delete_env("ARGUS_PRIORS_DIR")
    end)

    :ok = Cache.put(dir, @generation, "k1", %{state: %{}}, %{"answers" => %{}})
    :ok
  end

  test "status lists generations", %{tmp_dir: dir} do
    PriorsTask.run(["status"])
    assert_received {:mix_shell, :info, ["priors cache: " <> ^dir]}
    assert_received {:mix_shell, :info, ["  jev-test--Sensitivity--v1: 1 entries"]}
  end

  test "export then clear then import round-trips", %{tmp_dir: dir} do
    cassette = Path.join(dir, "cassette.jsonl")
    PriorsTask.run(["export", cassette])
    assert_received {:mix_shell, :info, ["wrote 1 entries to " <> _]}

    PriorsTask.run(["clear"])
    assert_received {:mix_shell, :info, ["removed 1 entries"]}
    assert Cache.entries(dir) == %{}

    PriorsTask.run(["import", cassette])
    assert_received {:mix_shell, :info, ["read 1 entries from " <> _]}
    assert {:ok, _} = Cache.get(dir, @generation, "k1")
  end

  test "anything else is usage" do
    assert_raise Mix.Error, ~r/usage/, fn -> PriorsTask.run(["frobnicate"]) end
  end
end
