defmodule Argus.Analyses.MailboxCoarseTest do
  @moduledoc """
  A target the bounded points-to stage resolves coarsely
  (`coarse_process`) is a process the target's source reaches anywhere
  in the program: one a send or a call may reach, not one it does. The
  mailbox analysis reports a message such a target is sent only when
  every process the site may reach is a server of one module: a send
  to one of two modules' servers is reported for neither, and a cast a
  server makes to itself by its name still is.

  The coarse resolution is forced by a copy of the rules whose exact
  stage is the coarse one (`stage_mode("coarse")`), over the same
  fixtures the exact stage resolves.
  """
  # Not async: the copy of the rules is argus's own for the test's length
  # (`:dl_root`, application-wide).
  use ExUnit.Case, async: false
  @moduletag :flowlog
  @moduletag :tmp_dir
  # The copy's engine is built once per version of the rules.
  @moduletag timeout: 1_800_000

  alias Argus.Test.Fixtures.MailboxCoarse, as: C
  alias Argus.Test.Rows

  @modules [C.Left, C.Right, C.Sender, C.Self]

  defp analyze do
    assert {:ok, r} = Argus.analyze(@modules, :mailbox)
    r
  end

  defp coarse(tmp, fun) do
    root = Path.join(tmp, "dl")
    File.cp_r!(Argus.Dl.root(), root)
    path = Path.join(root, "points_to.dl")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        ~s|stage_mode("exact").|,
        ~s|stage_mode("exact").\nstage_mode("bounded").\nstage_mode("coarse").|
      )
    )

    Application.put_env(:argus_beam, :dl_root, root)

    try do
      fun.()
    after
      Application.delete_env(:argus_beam, :dl_root)
    end
  end

  defp unhandled(r), do: Rows.where(r, :mailbox, "unhandled_info", [])
  defp own(r), do: Rows.where(r, :mailbox, "reply_defect", kind: ["unhandled_cast"])

  defp sent_to_right?(rows), do: Enum.any?(rows, &(Enum.at(&1, 5) == inspect(C.Right)))

  test "exactly resolved, a send to one of two servers is checked against each", %{} do
    r = analyze()

    assert sent_to_right?(unhandled(r))
    assert [[mod | _]] = own(r)
    assert mod == inspect(C.Self)
  end

  test "coarsely resolved, it is checked against neither; a cast to itself still is",
       %{tmp_dir: tmp} do
    coarse(tmp, fn ->
      r = analyze()

      refute sent_to_right?(unhandled(r))
      assert [[mod | _]] = own(r)
      assert mod == inspect(C.Self)
    end)
  end
end
