defmodule Argus.Graph.FrontendSourceTest do
  @moduledoc """
  Where a module's diagnostics anchor when the compiler's recorded
  source path is not on this machine.
  """

  use ExUnit.Case, async: true

  alias Roux.{Database, Input, Runtime}

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

    db = Database.new()
    :ok = Roux.Lang.register_module(db, Argus.Graph.Frontend)
    :ok = Input.set(db, :module_set, :all, [module])
    :ok = Input.set(db, :beam_meta, module, %{path: beam_path, hash: :erlang.phash2(beam)})
    :ok = Input.set(db, :project_root, :all, dir)

    %{db: db, module: module, beam_path: beam_path, root: dir}
  end

  test "the recorded path's tail under the project root is the source", ctx do
    File.mkdir_p!(Path.join(ctx.root, "lib"))
    File.write!(Path.join([ctx.root, "lib", "relocated.ex"]), @src)

    assert Runtime.query(ctx.db, :module_source, ctx.module) ==
             Path.join([ctx.root, "lib", "relocated.ex"])
  end

  test "the longest existing tail wins, as an umbrella member's does", ctx do
    File.mkdir_p!(Path.join([ctx.root, "checkout", "lib"]))
    File.write!(Path.join([ctx.root, "checkout", "lib", "relocated.ex"]), @src)
    File.mkdir_p!(Path.join(ctx.root, "lib"))
    File.write!(Path.join([ctx.root, "lib", "relocated.ex"]), @src)

    assert Runtime.query(ctx.db, :module_source, ctx.module) ==
             Path.join([ctx.root, "checkout", "lib", "relocated.ex"])
  end

  test "nothing under the root: the beam itself", ctx do
    assert Runtime.query(ctx.db, :module_source, ctx.module) == ctx.beam_path
  end
end
