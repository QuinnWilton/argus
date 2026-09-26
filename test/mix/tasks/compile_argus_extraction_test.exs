defmodule Mix.Tasks.Compile.ArgusExtractionTest do
  @moduledoc """
  What extraction could not do is reported beside the findings — the
  analyses ran on partial facts — and is never a permanent memo: the
  next run extracts the module again.

  The Mix project stack, the working directory, application env and
  telemetry are VM-wide: the tests run in this module's peer
  (`Argus.Test.Peer`).
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Fixture, Peer}
  alias Roux.QueryLog

  @moduletag :souffle
  @moduletag timeout: 300_000

  # The two analyses with findings on the fixture (five of them).
  @quick [analyses: [:coupling, :mailbox]]

  setup_all do
    %{peer: Peer.start!()}
  end

  defp scry(diagnostics), do: Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

  defp partial(diagnostics) do
    diagnostics |> scry() |> Enum.filter(&(&1.message =~ "may be missing"))
  end

  defp findings(diagnostics) do
    diagnostics |> scry() |> Enum.filter(&String.starts_with?(&1.message, "[scry."))
  end

  test "a module extraction timed out on is reported, and retried next run", %{peer: peer} do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_extraction_timeout"),
        @quick,
        :depot_timeout
      )

    Fixture.in_peer(peer, copy, :depot_timeout, fn log ->
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
      assert length(findings(diagnostics)) == 3
      assert length(QueryLog.executions(log, :module_extraction)) == 5

      # And with nothing left to retry, the next run is a noop again.
      QueryLog.reset(log)
      assert {:noop, _} = Fixture.compile!()
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "a beam that cannot be read is reported, and the rest still analyzed", %{peer: peer} do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_extraction_garbage"),
        @quick,
        :depot_garbage
      )

    Fixture.in_peer(peer, copy, :depot_garbage, fn _log ->
      Fixture.compile!()

      File.write!(
        Path.join(Mix.Project.compile_path(), "Elixir.Depot.Garbage.beam"),
        "not a beam"
      )

      {_status, diagnostics} = Fixture.compile!()

      assert [lost] = partial(diagnostics)
      assert lost.message =~ "Depot.Garbage could not be extracted"
      assert length(findings(diagnostics)) == 3
    end)
  end
end
