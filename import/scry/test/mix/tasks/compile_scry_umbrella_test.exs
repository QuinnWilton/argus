defmodule Mix.Tasks.Compile.ScryUmbrellaTest do
  @moduledoc """
  An umbrella whose child appends `:scry` to its compilers. Mix runs a
  non-recursive compiler once at the umbrella root, where there is no
  app and no ebin; scry is recursive, so it runs inside each child that
  lists it and analyzes that child's beams. In its own peer
  (`Scry.Test.Peer`): the Mix project stack and the working directory
  are VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Fixture, Peer}

  @moduletag timeout: 300_000
  @moduletag :souffle

  @fixture Path.expand("../../fixtures/umbrella", __DIR__)

  setup do
    copy = Path.join(System.tmp_dir!(), "scry_umbrella")
    File.rm_rf!(copy)
    File.cp_r!(@fixture, copy)
    %{copy: copy, peer: Peer.start!()}
  end

  test "compiles from the umbrella root and analyzes the child per app", %{
    copy: copy,
    peer: peer
  } do
    Fixture.in_peer(peer, copy, :scry_umbrella_fixture, fn _log ->
      {_result, stderr} = Fixture.compile_io!()

      # The child's own flaw is found in its own file (paths are
      # relative to the child, where the compiler ran). Per-app: B.Loop's
      # beams are not in app a's scan, so the same send across the app
      # boundary (line 27) is not a finding — include_deps: true is the
      # escape hatch.
      assert [_one] = Regex.scan(~r/\[scry\.mailbox\]/, stderr)
      assert stderr =~ "╭─[lib/a.ex:8:5]"

      manifest = Path.join(copy, "_build/test/lib/a/.mix/compile.scry")
      assert File.exists?(manifest)
      refute File.exists?(Path.join(copy, "_build/test/lib/b/.mix/compile.scry"))
    end)
  end
end
