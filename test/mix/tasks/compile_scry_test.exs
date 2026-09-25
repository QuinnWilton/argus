defmodule Mix.Tasks.Compile.ScryTest do
  @moduledoc """
  The Mix compiler integration, driven through the REAL chain:
  `compile!()` runs `:elixir` (producing the beams) and
  then `:scry` (analyzing them) inside a checked-out fixture project.
  Each scry run builds a fresh roux database restored from the manifest,
  so every warm assertion exercises the cross-VM serialization path.

  The Mix project stack, the working directory and the telemetry the
  query log listens on are VM-wide, so every test runs in this module's
  peer (`Scry.Test.Peer`), and the module runs beside the others.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Fixture, Peer, QueryLog}

  @moduletag timeout: 300_000
  @moduletag :souffle

  setup_all do
    %{peer: Peer.start!()}
  end

  setup do
    %{copy: Path.join(System.tmp_dir!(), "scry_mix_depot")}
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

  defp scry_diagnostics({_status, diagnostics}) do
    Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
  end

  defp counts_by_code(diagnostics) do
    diagnostics
    |> Enum.map(&code_of/1)
    |> Enum.frequencies()
  end

  defp code_of(%{message: message}) do
    case Regex.run(~r/^\[scry\.([a-z_]+)\]/, message) do
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
      diags = scry_diagnostics(result)

      # The fixture goldens: two coupling findings at the tree
      # definition and two task findings. Nothing else from the default
      # set: Sonar's handle_info/2 has no catch-all, but nothing writes
      # its mailbox that it does not take — the one call it makes out is
      # a timed GenServer.call, whose late reply an alias drops.
      assert counts_by_code(diags) == %{"coupling" => 2, "mailbox" => 2}

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
               "help: restart-coupled siblings belong under `rest_for_one`"

      assert first_coupling.details =~ "├─["
      assert first_coupling.details =~ "coupling call"

      # Extraction ran for every fixture module.
      modules = QueryLog.executions(log, :module_extraction)
      assert length(modules) == length(Path.wildcard(Path.join(copy, "lib/**/*.ex")))

      manifest = Path.join(Mix.Project.manifest_path(), "compile.scry")
      assert File.exists?(manifest)
      assert File.exists?(Path.join(Mix.Project.manifest_path(), "compile.scry.diagnostics"))

      # ── warm noop ───────────────────────────────────────────────────
      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      # Prior findings re-emit from memo hits: same diagnostics, zero
      # extraction, zero solves.
      assert counts_by_code(diags) == %{"coupling" => 2, "mailbox" => 2}
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # The persisted diagnostics callback serves the same list.
      assert Mix.Tasks.Compile.Scry.diagnostics() != []

      # ── line-only edit (the headline) ───────────────────────────────
      # A comment shifts every line: :elixir rewrites the beam
      # (Line/Dbgi chunks), scry re-extracts exactly that module, the
      # semantic facts compare equal, and NO solve re-runs — while the
      # reported line moves down by one.
      application = Path.join(copy, "lib/depot/application.ex")
      [%{position: line_before} | _] = coupling
      edit!(application, "# a comment\n" <> File.read!(application))

      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      assert QueryLog.executions(log, :module_extraction) == [Depot.Application]
      assert QueryLog.executions(log, :souffle_solve) == []

      coupling = Enum.filter(diags, &(code_of(&1) == "coupling"))
      assert [%{position: line_after} | _] = coupling
      assert line_after == line_before + 1

      # ── semantic edit ───────────────────────────────────────────────
      # one_for_one → rest_for_one clears the coupling findings; the
      # leaked task remains.
      rewritten =
        application
        |> File.read!()
        |> String.replace(":one_for_one", ":rest_for_one")

      edit!(application, rewritten)

      QueryLog.reset(log)
      result = compile!()
      diags = scry_diagnostics(result)

      assert counts_by_code(diags) == %{"mailbox" => 2}
      assert :coupling in QueryLog.executions(log, :souffle_solve)

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

      assert scry_diagnostics(result) == []
      assert :mailbox in QueryLog.executions(log, :souffle_solve)

      # And a further run is a clean noop.
      QueryLog.reset(log)
      result = compile!()
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []
      assert scry_diagnostics(result) == []
    end)
  end
end
