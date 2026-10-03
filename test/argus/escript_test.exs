defmodule Argus.EscriptTest do
  @moduledoc """
  The built `argus` escript, run as a user runs it: from a directory
  outside this repository, over fixture projects built without their
  tools (`Argus.Test.Projects`), with a store of its own.

  It prints what `Argus.CLI.run/1` prints in this VM, exits as it
  exits, unpacks its rules into the store on its first run, and keys
  the project's manifest on its own digest.

  Tagged `:escript` (building it takes a while, in `:prod`): `mix test
  --include escript`, and CI's escript job.
  """

  use ExUnit.Case, async: false
  @moduletag :escript
  @moduletag :souffle
  @moduletag timeout: 600_000

  import ExUnit.CaptureIO

  alias Argus.Test.Projects

  @repo Path.expand("../..", __DIR__)

  setup_all do
    bin = Argus.Test.Escript.build!()
    dir = Path.join(System.tmp_dir!(), "argus_escript_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, bin: bin, store: Path.join(dir, "store")}
  end

  # Its stdout and status; its stderr (the report, in text) goes to a
  # file, which a test reads when it wants it.
  defp escript(context, argv, cwd) do
    System.cmd("sh", ["-c", ~S(exec "$0" "$@" 2>>"$ARGUS_TEST_STDERR"), context.bin | argv],
      cd: cwd,
      env: [
        {"ARGUS_CACHE_DIR", context.store},
        {"ARGUS_TEST_STDERR", Path.join(context.dir, "stderr")}
      ]
    )
  end

  # Each finding with its files relative to the project's root.
  defp findings(json, root) do
    for finding <- JSON.decode!(json) do
      finding
      |> Map.update!("file", &Path.relative_to(Path.expand(&1, root), root))
      |> Map.update!("related", fn related ->
        for frame <- related,
            do: Map.update!(frame, "file", &Path.relative_to(Path.expand(&1, root), root))
      end)
    end
  end

  # rebar3_argus passes `--color always` whenever rebar3 has a terminal.
  # In the escript no loaded module names :always or :never yet, so these
  # values are the ones an atom lookup would miss.
  test "every --color and --format value parses", context do
    root = Projects.synthesize!(:rebar3_app, Path.join(context.dir, "rebar3_flags"))

    for color <- ~w(auto always never), format <- ~w(text json) do
      argv = ["--analyses", "coupling", "--color", color, "--format", format]
      assert {_, 0} = escript(context, argv, root), "--color #{color} --format #{format}"
    end
  end

  test "from outside the repository it finds what the CLI in this VM finds", context do
    root = Projects.synthesize!(:rebar3_app, Path.join(context.dir, "rebar3_app"))
    argv = ["--analyses", "coupling,failure", "--format", "json", "--include-deps"]

    {json, 0} = escript(context, argv, root)

    {in_vm, _stderr} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          assert Argus.CLI.run([root, "--state-dir", Path.join(root, ".in-vm") | argv]) == 0
        end)
      end)

    assert findings(json, root) == findings(in_vm, root)
    assert [_, _] = findings(json, root)

    # Its rules, unpacked on the first run; the manifest, keyed on the
    # escript's own digest.
    assert [digest] = File.ls!(Path.join(context.store, "dl"))
    assert digest == Argus.Dl.Embedded.digest()

    assert File.read!(Path.join(root, "_build/default/argus/escript")) ==
             :crypto.hash(:sha256, File.read!(context.bin)) |> Base.encode16(case: :lower)
  end

  test "exit statuses, and a Mix project referred to mix argus", context do
    root = Projects.synthesize!(:gleam_app, Path.join(context.dir, "gleam_app"))

    {_out, 1} = escript(context, ["--analyses", "failure", "--fail-above", "0"], root)
    {_out, 0} = escript(context, ["--analyses", "failure", "--fail-above", "5"], root)
    {_out, 2} = escript(context, ["--format", "xml"], root)
    {version, 0} = escript(context, ["version"], root)
    assert version =~ "argus "

    {out, 2} = System.cmd(context.bin, [@repo], stderr_to_stdout: true)
    assert out =~ "is a Mix project: run `mix argus` in it"
  end

  test "a Gleam finding is shown in the Erlang its build generated", context do
    root = Projects.synthesize!(:gleam_app, Path.join(context.dir, "gleam_frames"))

    {json, 0} = escript(context, ["--analyses", "failure", "--format", "json"], root)

    assert [%{"file" => file, "line" => 26}] =
             Enum.filter(findings(json, root), &(&1["title"] == "Unlinked process spawned"))

    assert file == "build/dev/erlang/gleam_app/_gleam_artefacts/gleam_app@worker.erl"
  end
end
