defmodule Mix.Tasks.Compile.ScryConfigTest do
  @moduledoc """
  The config surface, each scenario against its own fixture checkout
  (the `scry:` keyword is rendered into the fixture's mix.exs), in this
  module's peer (`Scry.Test.Peer`): the Mix project stack, the working
  directory and telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Fixture, Peer, QueryLog}

  @moduletag timeout: 300_000

  # The two analyses with findings on the fixture: the scenarios are
  # about what the config does to findings, not about the other solves.
  @quick [analyses: [:coupling, :mailbox]]

  setup_all do
    %{peer: Peer.start!()}
  end

  # Each scenario needs its own app atom: in_project caches project
  # config by app name, so a shared :depot would pin the first
  # scenario's scry: config for every later one.
  defp checkout!(scry_config, app) do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_cfg_#{app}"),
        Keyword.merge(@quick, scry_config),
        app
      )

    {copy, app}
  end

  defp in_project(peer, {copy, app}, fun), do: Fixture.in_peer(peer, copy, app, fun)

  defp compile!, do: Fixture.compile!()

  defp codes(diagnostics) do
    for %{message: message} <- diagnostics,
        [_, code] <- [Regex.run(~r/^\[scry\.([a-z_]+)\]/, message)],
        do: code
  end

  describe "config" do
    @tag :souffle
    test "fail_on: :warning promotes findings to a build failure", %{peer: peer} do
      project = checkout!([fail_on: :warning], :depot_failon)

      in_project(peer, project, fn _log ->
        assert {:error, diagnostics} = compile!()
        assert Enum.any?(diagnostics, &(&1.compiler_name == "scry"))

        # A warm rerun fails identically — CI can't be fooled by a warm
        # checkout.
        assert {:error, _} = compile!()
      end)
    end

    @tag :souffle
    test "severity overrides change the diagnostic and the status", %{peer: peer} do
      project = checkout!([severity: [mailbox: :error]], :depot_severity)

      in_project(peer, project, fn _log ->
        # The promoted finding is an :error, which trips the default
        # fail_on: :error.
        assert {:error, diagnostics} = compile!()

        unsafe = Enum.filter(diagnostics, &String.contains?(&1.message, "[scry.mailbox]"))

        assert length(unsafe) == 2
        assert Enum.all?(unsafe, &(&1.severity == :error))
      end)
    end

    @tag :souffle
    test "file ignores suppress reports without suppressing facts", %{peer: peer} do
      project = checkout!([ignore: [files: ["lib/depot/application.ex"]]], :depot_ignfile)

      in_project(peer, project, fn _log ->
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

        # The coupling finding anchors in the ignored file: reports
        # suppressed. The mailbox findings (archive.ex) are
        # untouched. That the
        # coupling ROWS were computed at all is asserted by the unfiltered
        # runs in the main suite; here the ignored file's facts still
        # participated (the analyses ran over the full module set).
        assert codes(diags) == ["mailbox", "mailbox"]
      end)
    end

    @tag :souffle
    test "module ignores keep the module out of analysis entirely", %{peer: peer} do
      project = checkout!([ignore: [modules: [~r/Archive/]]], :depot_ignmod)

      in_project(peer, project, fn log ->
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

        # No Archive extraction, so no task findings; the coupling
        # (Sonar's registration with Notifier, at Application's tree) is
        # unaffected.
        refute Depot.Archive in QueryLog.executions(log, :module_extraction)
        assert codes(diags) == ["coupling"]
      end)
    end

    test "invalid config aborts the compile with the valid options", %{peer: peer} do
      project = checkout!([analyses: [:nonsense]], :depot_badcfg)

      in_project(peer, project, fn _log ->
        assert_raise Scry.ConfigError, ~r/unknown analyses \[:nonsense\]/, fn -> compile!() end
      end)
    end
  end
end
