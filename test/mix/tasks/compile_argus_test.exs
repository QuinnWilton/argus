defmodule Mix.Tasks.Compile.ArgusTest do
  @moduledoc """
  The Mix compiler integration, driven through the REAL chain:
  `compile!()` runs `:elixir` (producing the beams) and
  then `:argus` (analyzing them) inside a checked-out fixture project.
  Each argus run builds a fresh roux database restored from the manifest,
  so every warm assertion exercises the cross-VM serialization path.

  The Mix project stack, the working directory and the telemetry the
  query log listens on are VM-wide, so every test runs in this module's
  peer (`Argus.Test.Peer`), and the module runs beside the others.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Fixture, Peer}
  alias Roux.QueryLog

  @moduletag timeout: 300_000
  @moduletag :souffle

  setup_all do
    %{peer: Peer.start!()}
  end

  setup do
    %{copy: Path.join(System.tmp_dir!(), "argus_mix_depot")}
  end

  defp compile!, do: Fixture.compile!()

  # Writes a fixture source and bumps its mtime forward: back-to-back
  # edits inside one posix second are invisible to :elixir's
  # second-granularity staleness check.
  defp edit!(path, content) do
    File.write!(path, content)

    bump = Process.get({__MODULE__, :bump}, 0) + 1
    Process.put({__MODULE__, :bump}, bump)
    File.touch!(path, System.os_time(:second) + bump)
  end

  defp argus_diagnostics({_status, diagnostics}) do
    Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
  end

  defp counts_by_code(diagnostics) do
    diagnostics
    |> Enum.map(&code_of/1)
    |> Enum.frequencies()
  end

  defp code_of(%{message: message}) do
    case Regex.run(~r/^\[argus\.([a-z_]+)\]/, message) do
      [_, code] -> code
      nil -> :infrastructure
    end
  end

  test "cold build, warm noop, line-only edit, semantic edit, deleted file", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy)

    Fixture.in_peer(peer, copy, :depot, fn log ->
      # ── cold build ──────────────────────────────────────────────────
      result = compile!()
      diags = argus_diagnostics(result)

      # The fixture goldens: one coupling finding at the tree definition
      # (Sonar's listener registration, which Notifier keeps) and two
      # task findings. Queue notifies Notifier on each use and holds
      # nothing there. Nothing else from the default set: Sonar's
      # handle_info/2 has no catch-all, which is no finding by itself, and
      # nothing writes its mailbox that it does not take.
      assert counts_by_code(diags) == %{"coupling" => 1, "mailbox" => 2}

      coupling = Enum.filter(diags, &(code_of(&1) == "coupling"))
      assert Enum.all?(coupling, &String.ends_with?(&1.file, "lib/depot/application.ex"))
      assert Enum.all?(coupling, &is_integer(&1.position))
      assert Enum.all?(coupling, &(&1.severity == :warning))

      # The rendered frame carries the anchor label, the excerpt, the
      # remediation, and the cross-file evidence as a continuation frame.
      [first_coupling | _] = coupling
      assert first_coupling.details =~ "╭─[lib/depot/application.ex:"
      assert first_coupling.details =~ "supervision tree defined here"

      assert first_coupling.details =~
               "help: put the pair under `rest_for_one` with `Depot.Notifier` started"

      # The two related frames: Sonar's listen from handle_continue/2 and
      # the Notifier clause that keeps it.
      assert first_coupling.details =~ "├─[lib/depot/sonar.ex:"
      assert first_coupling.details =~ "registers with the sibling here"
      assert first_coupling.details =~ "├─[lib/depot/notifier.ex:"
      assert first_coupling.details =~ "kept here"

      # Extraction ran for every fixture module.
      modules = QueryLog.executions(log, :module_facts)
      assert length(modules) == length(Path.wildcard(Path.join(copy, "lib/**/*.ex")))

      manifest = Path.join(Mix.Project.manifest_path(), "compile.argus")
      assert File.exists?(manifest)
      assert File.exists?(Path.join(Mix.Project.manifest_path(), "compile.argus.diagnostics"))

      # ── warm noop ───────────────────────────────────────────────────
      QueryLog.reset(log)
      result = compile!()
      diags = argus_diagnostics(result)

      # Prior findings re-emit from memo hits: same diagnostics, zero
      # extraction, zero solves.
      assert counts_by_code(diags) == %{"coupling" => 1, "mailbox" => 2}
      assert QueryLog.executions(log, :module_facts) == []
      assert QueryLog.executions(log, :solve) == []

      # The persisted diagnostics callback serves the same list.
      assert Mix.Tasks.Compile.Argus.diagnostics() != []

      # ── line-only edit (the headline) ───────────────────────────────
      # A comment shifts every line: :elixir rewrites the beam
      # (Line/Dbgi chunks), argus re-extracts exactly that module, the
      # semantic facts compare equal, and NO solve re-runs — while the
      # reported line moves down by one.
      application = Path.join(copy, "lib/depot/application.ex")
      [%{position: line_before} | _] = coupling
      edit!(application, "# a comment\n" <> File.read!(application))

      QueryLog.reset(log)
      result = compile!()
      diags = argus_diagnostics(result)

      assert [extracted] = QueryLog.executions(log, :module_facts)
      assert String.ends_with?(extracted, "/Elixir.Depot.Application.beam")
      assert QueryLog.executions(log, :solve) == []

      coupling = Enum.filter(diags, &(code_of(&1) == "coupling"))
      assert [%{position: line_after} | _] = coupling
      assert line_after == line_before + 1

      # ── semantic edit ───────────────────────────────────────────────
      # one_for_one → rest_for_one clears the coupling finding (a
      # Notifier restart now restarts Sonar, which listens again); the
      # leaked task remains.
      rewritten =
        application
        |> File.read!()
        |> String.replace(":one_for_one", ":rest_for_one")

      edit!(application, rewritten)

      QueryLog.reset(log)
      result = compile!()
      diags = argus_diagnostics(result)

      assert counts_by_code(diags) == %{"mailbox" => 2}
      assert {:project, :coupling} in QueryLog.executions(log, :solve)

      # ── deleted file ────────────────────────────────────────────────
      # Removing the module with the leaked task prunes its beam; the
      # input is GC'd and the findings disappear.
      # The diagnostic's file is absolute (and realpath'd — /private/var
      # while the checkout says /var); remove it directly.
      # Both task findings anchor in the same file, and they were the
      # last ones: the mailbox analysis re-solves to nothing.
      assert Enum.all?(diags, &String.ends_with?(&1.file, "archive.ex"))
      [unsafe | _] = diags
      File.rm!(unsafe.file)

      QueryLog.reset(log)
      result = compile!()

      assert argus_diagnostics(result) == []
      assert {:project, :mailbox} in QueryLog.executions(log, :solve)

      # And a further run is a clean noop.
      QueryLog.reset(log)
      result = compile!()
      assert QueryLog.executions(log, :module_facts) == []
      assert QueryLog.executions(log, :solve) == []
      assert argus_diagnostics(result) == []
    end)
  end
end
