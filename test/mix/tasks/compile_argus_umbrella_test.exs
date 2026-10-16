defmodule Mix.Tasks.Compile.ArgusUmbrellaTest do
  @moduledoc """
  An umbrella whose child appends `:argus` to its compilers. Mix runs a
  non-recursive compiler once at the umbrella root, where there is no
  app and no ebin; argus is recursive, so it runs inside each child that
  lists it and analyzes that child's beams. In its own peer
  (`Argus.Test.Peer`): the Mix project stack and the working directory
  are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO, only: [with_io: 1, with_io: 2]

  alias Argus.Test.{Fixture, Peer}

  # An umbrella's compile in a peer: minutes on a runner whose cores
  # Cargo is also building engines on.
  @moduletag timeout: 900_000
  @moduletag :flowlog

  @fixture Path.expand("../../projects/umbrella", __DIR__)

  setup do
    copy = Path.join(System.tmp_dir!(), "argus_umbrella")
    File.rm_rf!(copy)
    File.cp_r!(@fixture, copy)
    %{copy: copy, peer: Peer.start!()}
  end

  test "compiles from the umbrella root and analyzes the child per app", %{
    copy: copy,
    peer: peer
  } do
    Fixture.in_peer(peer, copy, :argus_umbrella_fixture, fn _log ->
      {_result, stderr} = Fixture.compile_io!()

      # The child's own flaw is found in its own file (paths are
      # relative to the child, where the compiler ran). Per-app: B.Loop's
      # beams are not in app a's scan, so the same send across the app
      # boundary (line 27) is not a finding — include_deps: true is the
      # escape hatch.
      assert [_one] = Regex.scan(~r/\[argus\.mailbox\]/, stderr)
      assert stderr =~ "╭─[lib/a.ex:8:5]"

      manifest = Path.join(copy, "_build/test/lib/a/.mix/compile.argus")
      assert File.exists?(manifest)
      refute File.exists?(Path.join(copy, "_build/test/lib/b/.mix/compile.argus"))

      # Warm, nothing compiles and only argus reports: under the child's
      # `==> a`, which Mix prints only for output through its shell.
      {_result, stdout, stderr} = Fixture.compile_stdio!()
      assert stderr =~ "[argus.mailbox]"
      assert stdout =~ "==> a\n"

      # `mix argus` reports each child under its name; b lists no :argus
      # compiler but is analyzed too, with nothing to say. The reports go to
      # stderr, the names to stdout, as a compile's warnings do.
      Mix.Task.clear()

      {{[:ok, :ok], report}, headers} =
        with_io(fn -> with_io(:stderr, fn -> Mix.Task.run("argus", []) end) end)

      assert headers == "==> b\n==> a\n"
      assert report =~ ~r/\A0 findings\n.*\[argus\.mailbox\].*\n1 finding /s
    end)
  end
end
