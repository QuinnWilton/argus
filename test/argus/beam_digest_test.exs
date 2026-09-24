defmodule Argus.BeamDigestTest do
  @moduledoc """
  A beam's digest names its code, not the tree it was built in: the
  corpus facts cache and the specs environment digest key on it, and a
  second worktree of one commit has to hit.
  """

  use ExUnit.Case, async: true

  alias Argus.BeamDigest

  # The trees live outside the working directory: Elixir names a source
  # file in the line table relative to the working directory when it can,
  # and a real build's working directory is its own root. A tree under
  # this project's `tmp/` would be named relative to argus instead.
  setup do
    tmp = Path.join(System.tmp_dir!(), "argus-beam-digest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp_dir: tmp}
  end

  # Builds `source` as if a project at `root` had compiled it: the source
  # under `root/lib`, the beam under `root/_build/test/lib/probe/ebin`.
  # The module is unloaded again so a second build of the same name in
  # this test is not a redefinition. Debug info is kept per module
  # (`@compile :debug_info`), since `mix test` compiles without it.
  defp build(root, module, source) do
    file = Path.join([root, "lib", "probe.ex"])
    [{^module, beam}] = Code.compile_string(source, file)
    :code.purge(module)
    :code.delete(module)

    ebin = Path.join([root, "_build", "test", "lib", "probe", "ebin"])
    File.mkdir_p!(ebin)
    path = Path.join(ebin, "#{module}.beam")
    File.write!(path, beam)
    path
  end

  defp probe(module, opts) do
    returns = Keyword.get(opts, :returns, ":ok")
    doc = Keyword.get(opts, :doc, "A probe.")

    """
    defmodule #{inspect(module)} do
      @moduledoc "#{doc}"
      @compile :debug_info
      @dir __DIR__
      @spec run() :: term()
      def run, do: {@dir, #{returns}, fn -> __ENV__.file end}
    end
    """
  end

  defp module, do: Module.concat(__MODULE__, "Probe#{System.unique_integer([:positive])}")

  defp digest!(beam, opts \\ []) do
    {:ok, digest} = BeamDigest.digest(beam, opts)
    digest
  end

  test "one source built in two trees digests the same, with or without debug info",
       %{tmp_dir: tmp} do
    mod = module()
    a = build(Path.join(tmp, "worktree-a"), mod, probe(mod, []))
    b = build(Path.join(tmp, "elsewhere/worktree-b"), mod, probe(mod, []))

    # The bytes differ: the literals, the compile info and the debug
    # info all carry the tree's path.
    assert File.read!(a) != File.read!(b)

    assert digest!(a) == digest!(b)
    assert digest!(a, debug_info: true) == digest!(b, debug_info: true)
  end

  test "a change to the code moves the digest", %{tmp_dir: tmp} do
    mod = module()
    a = build(Path.join(tmp, "a"), mod, probe(mod, returns: ":ok"))
    b = build(Path.join(tmp, "b"), mod, probe(mod, returns: "{:error, :changed}"))

    assert digest!(a) != digest!(b)
    assert digest!(a, debug_info: true) != digest!(b, debug_info: true)
  end

  test "prose that moves no line leaves the code digest alone", %{tmp_dir: tmp} do
    mod = module()
    a = build(Path.join(tmp, "a"), mod, probe(mod, doc: "A probe."))
    b = build(Path.join(tmp, "b"), mod, probe(mod, doc: "The same probe, described again."))

    assert digest!(a) == digest!(b)
  end

  test "a moved line moves the digest: a crash's location can reach a fact", %{tmp_dir: tmp} do
    mod = module()
    a = build(Path.join(tmp, "a"), mod, probe(mod, []))
    b = build(Path.join(tmp, "b"), mod, "\n# A comment above the module.\n" <> probe(mod, []))

    assert digest!(a) != digest!(b)
  end

  test "debug info counts only when asked for", %{tmp_dir: tmp} do
    mod = module()
    source = probe(mod, [])
    a = build(Path.join(tmp, "a"), mod, source)

    b =
      build(
        Path.join(tmp, "b"),
        mod,
        String.replace(source, "@spec run() :: term()", "@spec run() :: tuple()")
      )

    assert digest!(a) == digest!(b)
    assert digest!(a, debug_info: true) != digest!(b, debug_info: true)
  end

  test "a path outside the build root is not normalized away", %{tmp_dir: tmp} do
    mod = module()
    a = build(Path.join(tmp, "a"), mod, probe(mod, returns: ~s("/srv/one")))
    b = build(Path.join(tmp, "b"), mod, probe(mod, returns: ~s("/srv/two")))

    assert digest!(a) != digest!(b)
  end

  test "the build root is the directory holding the innermost _build" do
    assert BeamDigest.build_root("/w/a/_build/test/lib/x/ebin/X.beam") == "/w/a"

    assert BeamDigest.build_root("/w/a/deps/y/_build/dev/lib/y/ebin/Y.beam") ==
             "/w/a/deps/y"

    assert BeamDigest.build_root("/usr/lib/erlang/lib/stdlib/ebin/lists.beam") == nil
  end

  test "an unreadable beam is an error, not a digest", %{tmp_dir: tmp} do
    missing = Path.join(tmp, "Missing.beam")
    assert {:error, _reason} = BeamDigest.digest(missing)

    garbage = Path.join(tmp, "Garbage.beam")
    File.write!(garbage, "not a beam")
    assert {:error, _reason} = BeamDigest.digest(garbage)
  end
end
