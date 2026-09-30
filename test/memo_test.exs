defmodule Argus.Test.MemoTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  @moduletag :tmp_dir
  @answer {:ok, %{"probe" => [["1"]]}}

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
            :go -> Memo.analyze([], {:custom, program})
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    assert Enum.map(tasks, &Task.await(&1, 30_000)) == List.duplicate(@answer, 8)
    assert_received :solving
    refute_received :solving

    assert Memo.analyze([], {:custom, program}) == @answer
    refute_received :solving
  end

  test "calls with options bypass the shared answer", %{program: program} do
    write_program(program)
    assert Memo.analyze([], {:custom, program}) == @answer
    assert_received :solving

    assert Memo.analyze([], {:custom, program}, timeout: 30_000) == @answer
    assert_received :solving
  end

  test "failures are retried", %{program: program} do
    assert {:error, _} = Memo.analyze([], {:custom, program})
    write_program(program)
    assert Memo.analyze([], {:custom, program}) == @answer
  end

  defp write_program(path) do
    File.write!(path, ".decl probe(x: number)\n.output probe\nprobe(1).\n")
  end
end
