defmodule Argus.Graph.FrontendSourceTest do
  @moduledoc """
  Where a module's findings anchor when the compiler's recorded source
  path is not on this machine (`Argus.Graph.Frontend`'s `module_source`).
  """

  use ExUnit.Case, async: true

  alias Argus.Graph.Frontend
  alias Roux.Input

  @moduletag :tmp_dir

  @src """
  defmodule Argus.Graph.FrontendSourceTest.Relocated do
    def hello, do: :world
  end
  """

  setup %{tmp_dir: dir} do
    recorded = "/somewhere/else/checkout/lib/relocated.ex"
    [{module, beam}] = Code.compile_string(@src, recorded)
    :code.purge(module)
    :code.delete(module)

    ebin = Path.join([dir, "_build", "dev", "lib", "app", "ebin"])
    File.mkdir_p!(ebin)
    beam_path = Path.join(ebin, "#{module}.beam")
    File.write!(beam_path, beam)

    session = Argus.Graph.open(store: Roux.Blob.temporary())
    on_exit(fn -> Roux.Blob.destroy(session.blob) end)
    [key] = Argus.Graph.set_program(session.db, :test, [beam_path])
    :ok = Input.set(session.db, :project_root, :all, dir)

    %{db: session.db, key: key, beam_path: beam_path, root: dir}
  end

  test "the recorded path's tail under the project root is the source", ctx do
    File.mkdir_p!(Path.join(ctx.root, "lib"))
    File.write!(Path.join([ctx.root, "lib", "relocated.ex"]), @src)

    assert Frontend.module_source(ctx.db, ctx.key) == Path.join([ctx.root, "lib", "relocated.ex"])
  end

  test "the longest existing tail wins, as an umbrella member's does", ctx do
    File.mkdir_p!(Path.join([ctx.root, "checkout", "lib"]))
    File.write!(Path.join([ctx.root, "checkout", "lib", "relocated.ex"]), @src)
    File.mkdir_p!(Path.join(ctx.root, "lib"))
    File.write!(Path.join([ctx.root, "lib", "relocated.ex"]), @src)

    assert Frontend.module_source(ctx.db, ctx.key) ==
             Path.join([ctx.root, "checkout", "lib", "relocated.ex"])
  end

  test "nothing under the root: the beam itself", ctx do
    assert Frontend.module_source(ctx.db, ctx.key) == ctx.beam_path
  end
end
