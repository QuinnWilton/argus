defmodule Mix.Tasks.Compile.ScryConfigTest do
  @moduledoc """
  The config surface and the souffle gate, each scenario against its own
  fixture checkout (the `scry:` keyword is rendered into the fixture's
  mix.exs).
  """

  # Mix project stack + cwd + PATH manipulation — never async.
  use ExUnit.Case, async: false

  alias Roux.Lang.Manifest
  alias Scry.Test.{Fixture, QueryLog}

  @moduletag timeout: 300_000

  setup do
    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)
    %{log: log}
  end

  # Each scenario needs its own app atom: in_project caches project
  # config by app name, so a shared :depot would pin the first
  # scenario's scry: config for every later one.
  defp checkout!(scry_config, app) do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_cfg_#{app}"),
        scry_config,
        app
      )

    {copy, app}
  end

  defp compile!, do: Fixture.compile!()

  defp codes(diagnostics) do
    for %{message: message} <- diagnostics,
        [_, code] <- [Regex.run(~r/^\[scry\.([a-z_]+)\]/, message)],
        do: code
  end

  describe "config" do
    @tag :souffle
    test "fail_on: :warning promotes findings to a build failure" do
      {copy, app} = checkout!([fail_on: :warning], :depot_failon)

      Mix.Project.in_project(app, copy, fn _module ->
        assert {:error, diagnostics} = compile!()
        assert Enum.any?(diagnostics, &(&1.compiler_name == "scry"))

        # A warm rerun fails identically — CI can't be fooled by a warm
        # checkout.
        assert {:error, _} = compile!()
      end)
    end

    @tag :souffle
    test "severity overrides change the diagnostic and the status" do
      {copy, app} = checkout!([severity: [mailbox: :error]], :depot_severity)

      Mix.Project.in_project(app, copy, fn _module ->
        # The promoted finding is an :error, which trips the default
        # fail_on: :error.
        assert {:error, diagnostics} = compile!()

        unsafe = Enum.filter(diagnostics, &String.contains?(&1.message, "[scry.mailbox]"))

        assert length(unsafe) == 3
        assert Enum.all?(unsafe, &(&1.severity == :error))
      end)
    end

    @tag :souffle
    test "file ignores suppress reports without suppressing facts" do
      {copy, app} = checkout!([ignore: [files: ["lib/depot/application.ex"]]], :depot_ignfile)

      Mix.Project.in_project(app, copy, fn _module ->
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

        # The coupling findings anchor in the ignored file: reports
        # suppressed. The mailbox findings (archive.ex, sonar.ex) are
        # untouched. That the
        # coupling ROWS were computed at all is asserted by the unfiltered
        # runs in the main suite; here the ignored file's facts still
        # participated (the analyses ran over the full module set).
        assert codes(diags) == ["mailbox", "mailbox", "mailbox"]
      end)
    end

    @tag :souffle
    test "module ignores keep the module out of analysis entirely", %{log: log} do
      {copy, app} = checkout!([ignore: [modules: [~r/Archive/]]], :depot_ignmod)

      Mix.Project.in_project(app, copy, fn _module ->
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))

        # No Archive extraction, so no task findings; the couplings
        # (Sonar/Queue against Notifier via Application) and Sonar's
        # handle_info are unaffected.
        refute Depot.Archive in QueryLog.executions(log, :module_extraction)
        assert Enum.sort(codes(diags)) == ["coupling", "coupling", "mailbox"]
      end)
    end

    test "invalid config aborts the compile with the valid options" do
      {copy, app} = checkout!([analyses: [:nonsense]], :depot_badcfg)

      Mix.Project.in_project(app, copy, fn _module ->
        assert_raise Mix.Error, ~r/unknown analyses \[:nonsense\]/, fn -> compile!() end
      end)
    end
  end

  describe "souffle gate" do
    defp without_souffle(fun) do
      original = System.get_env("PATH")

      masked =
        original
        |> String.split(":")
        |> Enum.reject(fn dir ->
          souffle = Path.join(dir, "souffle")
          File.exists?(souffle)
        end)
        |> Enum.join(":")

      System.put_env("PATH", masked)

      try do
        fun.()
      after
        System.put_env("PATH", original)
      end
    end

    @tag :souffle
    test "souffle: :warn degrades with one notice and poisons nothing", %{log: log} do
      {copy, app} = checkout!([], :depot_nosolver)

      Mix.Project.in_project(app, copy, fn _module ->
        without_souffle(fn ->
          assert {:ok, diagnostics} = compile!()

          [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
          assert notice.severity == :information
          assert notice.message =~ "souffle binary not found"
          assert QueryLog.executions(log, :souffle_solve) == []
        end)

        # No solve memo — not even an error one — reached the manifest.
        {:ok, manifest} = Manifest.load(Path.join(Mix.Project.manifest_path(), "compile.scry"))

        refute Enum.any?(Manifest.memo_entries(manifest), fn {key, _entry} ->
                 match?({:souffle_solve, _}, key)
               end)

        # Souffle back on PATH: the fingerprint moves, analyses run, the
        # findings appear — the degraded run healed completely.
        assert {:ok, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
        assert length(diags) == 5
        assert QueryLog.executions(log, :souffle_solve) != []
      end)
    end

    test "souffle: :require makes the missing solver an error" do
      {copy, app} = checkout!([souffle: :require], :depot_require)

      Mix.Project.in_project(app, copy, fn _module ->
        without_souffle(fn ->
          assert {:error, diagnostics} = compile!()

          [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
          assert notice.severity == :error
          assert notice.message =~ "souffle binary not found"
        end)
      end)
    end
  end
end
