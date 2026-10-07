defmodule Argus.Test.MemoTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  @moduletag :tmp_dir
  # An engine keeps a program's answer as its inputs change, so the probe
  # reads one: the module each function is defined in.
  @modules [Argus.Test.Fixtures.OtherLoop]
  @answer {:ok, %{"probe" => [["Argus.Test.Fixtures.OtherLoop"]]}}

  setup %{tmp_dir: tmp} do
    program = Path.join(tmp, "probe.dl")
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:roux, :query, :start],
        &__MODULE__.query_started/4,
        {self(), program}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{program: program}
  end

  @doc false
  def query_started(
        _event,
        _measurements,
        %{query_name: :solve, key: {_, {:custom, program}}},
        {test, program}
      ),
      do: send(test, :solving)

  def query_started(_event, _measurements, _metadata, _config), do: :ok

  test "concurrent callers share one computation", %{program: program} do
    write_program(program)
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Memo.analyze(@modules, {:custom, program})
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    # The first solve builds the probe's engine: the test's own timeout
    # bounds the wait.
    assert Enum.map(tasks, &Task.await(&1, :infinity)) == List.duplicate(@answer, 8)
    assert_received :solving
    refute_received :solving

    assert Memo.analyze(@modules, {:custom, program}) == @answer
    refute_received :solving
  end

  test "calls with options bypass the shared answer", %{program: program} do
    write_program(program)
    assert Memo.analyze(@modules, {:custom, program}) == @answer
    assert_received :solving

    assert Memo.analyze(@modules, {:custom, program}, timeout: 30_000) == @answer
    assert_received :solving
  end

  test "failures are retried", %{program: program} do
    assert {:error, _} = Memo.analyze(@modules, {:custom, program})
    write_program(program)
    assert Memo.analyze(@modules, {:custom, program}) == @answer
  end

  defp write_program(path) do
    File.write!(path, """
    .include #{JSON.encode!(Argus.Dl.path("base.dl"))}
    .decl probe(mod: symbol)
    .output probe
    probe(m) :- function_def(_, m, _, _, _).
    """)
  end
end
