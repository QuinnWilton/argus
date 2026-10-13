defmodule Mix.Tasks.Argus.FlowlogTaskTest do
  @moduledoc """
  `mix argus.flowlog` in a project: the commands that manage argus's
  engines read the machine's cache, and neither compile the project nor
  run the `:argus` compiler's analyses on it. In a peer
  (`Argus.Test.Peer`): `ARGUS_FLOWLOG_DIR` is VM-wide.
  """
  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Fixture, Peer}

  @moduletag :tmp_dir

  test "status and clean leave the project uncompiled and unanalyzed", %{tmp_dir: tmp} do
    copy = Fixture.checkout!(Path.join(tmp, "project"), [], :depot_flowlog_task)
    root = Path.join(tmp, "cache")
    failure = Path.join([root, "prebuilt", String.duplicate("a", 64) <> ".failed"])

    output =
      Fixture.in_peer(Peer.start!(), copy, :depot_flowlog_task, fn _log ->
        System.put_env("ARGUS_FLOWLOG_DIR", root)
        File.mkdir_p!(Path.dirname(failure))
        File.write!(failure, "another release's")

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Task.run("argus.flowlog", ["status"])
            Mix.Task.rerun("argus.flowlog", ["clean"])
          end)

        refute File.exists?(Mix.Project.compile_path())
        refute File.exists?(Argus.Driver.manifest_file())
        output
      end)

    assert output =~ "cache:     #{root}"
    assert output =~ ~r/^prebuilt:  /m
    assert output =~ "removed 1 unused toolchain(s) and bundle(s)"
    refute File.exists?(failure)
  end
end
