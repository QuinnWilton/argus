defmodule Argus.CLITest do
  @moduledoc """
  The escript's command line, run in this VM (`Argus.CLI.run/1`, which
  returns the exit status rather than halting): the commands, the usage
  and configuration errors (2), a project that cannot be analyzed as
  asked (2), and an analysis of the rebar3 fixture (built without
  rebar3, `Argus.Test.Projects`) in text and JSON, with `--fail-above`
  (1). `Argus.EscriptTest` runs the built escript itself.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Argus.CLI
  alias Argus.CLI.Options
  alias Argus.Test.Projects

  @moduletag :tmp_dir

  defp run(argv) do
    {{status, stdout}, stderr} = with_io(:stderr, fn -> with_io(fn -> CLI.run(argv) end) end)
    %{status: status, stdout: stdout, stderr: stderr}
  end

  describe "commands" do
    test "help, version and list" do
      assert %{status: 0, stdout: usage} = run(["help"])
      assert usage =~ "Usage: argus [analyze] [DIR] [options]"
      assert %{status: 0, stdout: ^usage} = run(["--help"])

      assert %{status: 0, stdout: version} = run(["version"])
      assert version =~ ~r/^argus \S+ \(Erlang\/OTP \d+, Elixir [\d.]+, souffle/

      assert %{status: 0, stdout: list} = run(["list"])
      assert list =~ "* coupling"
      assert list =~ "security: unsafe_input exposure"
      refute list =~ "coverage"
    end
  end

  describe "usage errors exit 2" do
    test "an unknown option, a bad value, a stray argument" do
      for argv <- [
            ["--bogus"],
            ["--format", "xml"],
            ["--color", "sometimes"],
            ["--project", "maven"],
            ["analyze", "a", "b"],
            ["--app", "no-equals-sign"],
            ["--fail-above", "-1"],
            ["--project", "gleam", "--profile", "test"]
          ] do
        assert %{status: 2, stderr: stderr} = run(argv), inspect(argv)
        assert stderr =~ "Run `argus help` for the usage."
      end
    end
  end

  describe "a project that cannot be analyzed as asked exits 2" do
    test "no project, a Mix project, nothing built", %{tmp_dir: dir} do
      assert %{status: 2, stderr: stderr} = run([dir])
      assert stderr =~ "no rebar3, Gleam or erlang.mk project in #{dir}"

      File.write!(Path.join(dir, "mix.exs"), "")
      assert %{status: 2, stderr: stderr} = run([dir])
      assert stderr =~ "is a Mix project: run `mix argus` in it"

      unbuilt = Projects.copy!(:rebar3_app, Path.join(dir, "unbuilt"))
      assert %{status: 2, stderr: stderr} = run([unbuilt])
      assert stderr =~ "build it first (`rebar3 compile`)"

      assert %{status: 2, stderr: stderr} = run([Path.join(dir, "absent")])
      assert stderr =~ "is not a directory"
    end

    test "a configuration error names the entry in the file's syntax", %{tmp_dir: dir} do
      root = Projects.synthesize!(:erlang_mk_app, Path.join(dir, "app"))
      File.write!(Path.join(root, "argus.config"), "{analyses, [mailbx]}.\n")

      assert %{status: 2, stderr: stderr} = run([root])
      assert stderr =~ "unknown analyses [mailbx]"
      assert stderr =~ "did you mean mailbox?"
      assert stderr =~ "argus → analyses (in #{Path.join(root, "argus.config")})"

      File.write!(Path.join(root, "argus.config"), "{analyses, [mailbox]}.\n")
      assert %{status: 2, stderr: stderr} = run([root, "--analyses", "nonsense"])
      assert stderr =~ "unknown analyses [:nonsense]"
    end
  end

  describe "analyze" do
    @describetag :souffle
    @describetag timeout: 300_000

    setup %{tmp_dir: dir} do
      %{root: Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))}
    end

    test "the report on stderr; --fail-above decides the status", %{root: root} do
      assert %{status: 0, stdout: "", stderr: stderr} =
               run([root, "--analyses", "coupling,failure", "--color", "never"])

      assert stderr =~ "warning[argus.coupling]: Coupled children under one_for_one"
      assert stderr =~ "warning[argus.failure]: Unlinked process spawned"
      assert stderr =~ "2 findings (2 warnings)\n"
      refute stderr =~ "\e["

      assert %{status: 1} = run([root, "--analyses", "coupling,failure", "--fail-above", "1"])
      assert %{status: 0} = run([root, "--analyses", "coupling,failure", "--fail-above", "2"])
    end

    test "--format json: the findings on stdout", %{root: root} do
      assert %{status: 0, stdout: json} =
               run(["analyze", "--root", root, "--analyses", "coupling", "--format", "json"])

      assert [%{"analysis" => "coupling", "severity" => "warning"} = finding] = JSON.decode!(json)
      assert String.ends_with?(finding["file"], "apps/shop/src/shop_sup.erl")
      assert finding["line"] == 9
      assert length(finding["related"]) == 2
    end

    test "the configuration's own analyses, and the rebar3 plugin's exact ebins", %{root: root} do
      lib = Path.join(root, "_build/default/lib")

      assert %{status: 0, stderr: stderr} =
               run([
                 "--project",
                 "rebar3",
                 "--root",
                 root,
                 "--profile",
                 "default",
                 "--app",
                 "shop=#{Path.join(lib, "shop/ebin")}",
                 "--app",
                 "ledger=#{Path.join(lib, "ledger/ebin")}",
                 "--dep",
                 "telemetry=#{Path.join(root, "_build/default/checkouts/telemetry/ebin")}",
                 "--state-dir",
                 Path.join(root, "_build/default/argus"),
                 "--color",
                 "never"
               ])

      # rebar.config's {argus, [{analyses, [coupling, mailbox, blocking, startup]}]}.
      assert stderr =~ "warning[argus.coupling]"
      refute stderr =~ "argus.failure"
    end

    test "bare ebins", %{root: root} do
      assert %{status: 0, stderr: stderr} =
               run([
                 "--project",
                 "beams",
                 "--ebin",
                 Path.join(root, "_build/default/lib/ledger/ebin"),
                 "--analyses",
                 "failure",
                 "--state-dir",
                 Path.join(root, ".argus-beams")
               ])

      assert stderr =~ "Unlinked process spawned"
    end

    test "a source newer than its beam is named, with the build command", %{root: root} do
      File.touch!(Path.join(root, "apps/ledger/src/ledger.erl"), System.os_time(:second) + 60)

      assert %{status: 0, stderr: stderr} = run([root, "--analyses", "failure"])

      assert stderr =~
               "argus: 1 source is newer than its beam (apps/ledger/src/ledger.erl): " <>
                 "the findings are about the code as last built; run `rebar3 compile` first"
    end
  end

  describe "Options" do
    test "mix argus takes the analyses as arguments, and no project options" do
      assert {:ok, %Options{analyses: [:coupling, :ets]}} =
               Options.parse(["coupling", "ets"], :mix)

      assert {:ok, %Options{command: :list}} = Options.parse(["--list"], :mix)
      assert {:ok, %Options{all: true, analyses: nil}} = Options.parse(["--all"], :mix)
      assert {:error, _} = Options.parse(["--project", "rebar3"], :mix)
      assert {:error, message} = Options.parse(["coupling", "--analyses", "ets"], :mix)
      assert message =~ "name the analyses once"
    end
  end
end
