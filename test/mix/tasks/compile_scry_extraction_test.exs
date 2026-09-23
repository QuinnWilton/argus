defmodule Mix.Tasks.Compile.ScryExtractionTest do
  @moduledoc """
  What extraction could not do is reported beside the findings — the
  analyses ran on partial facts — and is never a permanent memo: the
  next run extracts the module again.
  """

  # Mix project stack + cwd + application env — never async.
  use ExUnit.Case, async: false

  alias Scry.Test.{Fixture, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  setup do
    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)
    %{log: log}
  end

  defp scry(diagnostics), do: Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

  defp partial(diagnostics) do
    diagnostics |> scry() |> Enum.filter(&(&1.message =~ "may be missing"))
  end

  defp findings(diagnostics) do
    diagnostics |> scry() |> Enum.filter(&String.starts_with?(&1.message, "[scry."))
  end

  test "a module extraction timed out on is reported, and retried next run", %{log: log} do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_extraction_timeout"),
        [],
        :depot_timeout
      )

    Mix.Project.in_project(:depot_timeout, copy, fn _module ->
      # Every module outlives a 0 ms budget: all of them lose their facts.
      Application.put_env(:scry, :extraction_timeout, 0)

      try do
        {_status, diagnostics} = Fixture.compile!()
        lost = partial(diagnostics)

        assert length(lost) == 5
        assert Enum.all?(lost, &(&1.severity == :warning))
        assert Enum.all?(lost, &(&1.message =~ "lost all its facts in extraction"))
        assert Enum.all?(lost, &(&1.message =~ "did not finish within 0 ms"))
      after
        Application.delete_env(:scry, :extraction_timeout)
      end

      # Nothing was edited, and the budget is back: the failed modules are
      # extracted again, and the findings are the fixture's.
      QueryLog.reset(log)
      {_status, diagnostics} = Fixture.compile!()

      assert partial(diagnostics) == []
      assert length(findings(diagnostics)) == 5
      assert length(QueryLog.executions(log, :module_extraction)) == 5

      # And with nothing left to retry, the next run is a noop again.
      QueryLog.reset(log)
      assert {:noop, _} = Fixture.compile!()
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "a beam that cannot be read is reported, and the rest still analyzed" do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_extraction_garbage"),
        [],
        :depot_garbage
      )

    Mix.Project.in_project(:depot_garbage, copy, fn _module ->
      Fixture.compile!()

      File.write!(
        Path.join(Mix.Project.compile_path(), "Elixir.Depot.Garbage.beam"),
        "not a beam"
      )

      {_status, diagnostics} = Fixture.compile!()

      assert [lost] = partial(diagnostics)
      assert lost.message =~ "Depot.Garbage could not be extracted"
      assert length(findings(diagnostics)) == 5
    end)
  end
end
