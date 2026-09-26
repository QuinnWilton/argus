defmodule Mix.Tasks.ArgusTest do
  @moduledoc """
  The standalone one-shot task, driven inside the fixture project. The
  compiler runs first (via the full chain), so the standalone runs
  exercise the shared-manifest warm path. In this module's peer
  (`Argus.Test.Peer`): the Mix project stack, the working directory and
  telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO

  alias Argus.Test.{Fixture, Peer}
  alias Roux.QueryLog

  @moduletag timeout: 300_000
  @moduletag :souffle

  # The two analyses with findings on the fixture (the five the reports
  # count); `--list` marks the default set whatever the config says.
  @quick [analyses: [:coupling, :mailbox]]

  # One checkout, compiled once: every test here reads the warm manifest
  # and none edits the fixture, so the cold compile is paid per module,
  # not per test. The `compile!()` each test opens with is then a no-op.
  setup_all do
    peer = Peer.start!()
    copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "scry_task_depot"), @quick)
    Fixture.in_peer(peer, copy, :depot, fn _log -> compile!() end)
    %{copy: copy, peer: peer}
  end

  defp in_project(%{peer: peer, copy: copy}, fun), do: Fixture.in_peer(peer, copy, :depot, fun)

  defp compile!, do: Fixture.compile!()

  test "runs warm off the compiler's manifest and reports", context do
    in_project(context, fn log ->
      compile!()

      # The standalone task shares the compiler's manifest: nothing
      # re-extracts, nothing re-solves.
      QueryLog.reset(log)

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("argus", [])
        end)

      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      assert output =~ "warning[scry.coupling]"
      assert output =~ "warning[scry.mailbox]"
      assert output =~ "3 findings (2 warnings, 1 info)"
    end)
  end

  test "--format json emits the stable schema", context do
    in_project(context, fn _log ->
      compile!()

      json =
        capture_io(fn ->
          Mix.Task.rerun("argus", ["--format", "json"])
        end)

      entries = JSON.decode!(json)
      assert length(entries) == 3

      assert [first] = Enum.filter(entries, &(&1["analysis"] == "coupling"))
      assert first["severity"] == "warning"
      assert first["file"] == "lib/depot/application.ex"
      assert is_integer(first["line"])
      assert first["title"] == "Coupled children under one_for_one"
      assert first["at_label"] == "supervision tree defined here"
      assert is_binary(first["detail"])
      assert first["provenance"] == "structural"
      assert Map.has_key?(first, "confidence") and is_nil(first["confidence"])
      assert Map.has_key?(first, "end_line")
      assert [help | _] = first["help"]
      assert help =~ "rest_for_one"

      # Sonar's listen from handle_continue/2, and the Notifier clause
      # that keeps it.
      assert Enum.any?(first["related"], fn related ->
               related["label"] == "registers with the sibling here" and
                 is_integer(related["line"]) and related["file"] == "lib/depot/sonar.ex"
             end)

      assert Enum.any?(first["related"], fn related ->
               related["label"] == "kept here" and is_integer(related["line"]) and
                 related["file"] == "lib/depot/notifier.ex"
             end)
    end)
  end

  test "--fail-above raises when the count is exceeded", context do
    in_project(context, fn _log ->
      compile!()

      assert_raise Mix.Error, ~r/3 findings exceed --fail-above 0/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["--fail-above", "0"]) end)
      end

      # At or below the threshold passes.
      capture_io(:stderr, fn ->
        assert Mix.Task.rerun("argus", ["--fail-above", "3"]) != :failed
      end)
    end)
  end

  test "positional analyses narrow the run; unknown names abort", context do
    in_project(context, fn _log ->
      compile!()

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("argus", ["mailbox"])
        end)

      assert output =~ "warning[scry.mailbox]"
      refute output =~ "scry.coupling"
      assert output =~ "2 findings (1 warning, 1 info)"

      assert_raise Argus.ConfigError, ~r/unknown analyses \[:nonsense\]/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["nonsense"]) end)
      end
    end)
  end

  test "--list names every analysis and marks the default set", context do
    in_project(context, fn _log ->
      output = capture_io(fn -> Mix.Task.rerun("argus", ["--list"]) end)

      assert output =~ "* coupling"
      assert output =~ "* mailbox"
      assert output =~ "  unsafe_input"
      assert output =~ "security: unsafe_input exposure"
      refute output =~ "coverage"
    end)
  end

  describe "the compile it runs first" do
    # Own checkouts with their own app atoms: in_project caches project
    # config by app name, and these need a scry: config of their own.
    test "a finding that fails the compiler's fail_on is reported, not fatal", %{peer: peer} do
      app = :depot_task_error

      copy =
        Fixture.checkout!(
          Path.join(System.tmp_dir!(), "scry_#{app}"),
          [severity: [mailbox: :error]] ++ @quick,
          app
        )

      Fixture.in_peer(peer, copy, app, fn _log ->
        # mix compile fails here: the mailbox findings are errors and
        # fail_on is :error. Built once so stdout carries only the JSON;
        # cleared so the task's own compile runs (warm) and sees :error.
        assert {:error, _diagnostics} = compile!()
        Mix.Task.clear()

        {json, _stderr} =
          with_io(:stderr, fn ->
            capture_io(fn -> Mix.Task.rerun("argus", ["--format", "json"]) end)
          end)

        entries = JSON.decode!(json)
        assert length(entries) == 3

        mailbox = Enum.filter(entries, &(&1["analysis"] == "mailbox"))
        assert length(mailbox) == 2
        assert Enum.all?(mailbox, &(&1["severity"] == "error"))
      end)
    end

    test "a project that does not compile is an error, with no report", %{peer: peer} do
      app = :depot_task_broken
      copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "scry_#{app}"), @quick, app)

      File.write!(
        Path.join(copy, "lib/depot/broken.ex"),
        "defmodule Depot.Broken do\n  def f(, do: :ok\nend\n"
      )

      Fixture.in_peer(peer, copy, app, fn _log ->
        Mix.Task.clear()

        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/does not compile/, fn ->
            capture_io(fn -> Mix.Task.rerun("argus", ["--format", "json"]) end)
          end
        end)
      end)
    end
  end
end
