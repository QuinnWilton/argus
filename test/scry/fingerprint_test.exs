defmodule Scry.FingerprintTest do
  # The souffle_version tests move PATH, which is VM-wide: they run in
  # this module's peer (`Scry.Test.Peer`), and the module runs async.
  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.Peer

  @moduletag :tmp_dir

  # A souffle that prints the real banner shape: a rule of dashes first,
  # the version on the line after it.
  defp fake_souffle!(dir, version, word_size \\ 64) do
    path = Path.join(dir, "souffle")

    File.write!(path, """
    #!/bin/sh
    cat <<'BANNER'
    ----------------------------------------------------------------------------
    Version: #{version}
    Word size: #{word_size} bits
    Options enabled: ffi ncurses sqlite zlib
    ----------------------------------------------------------------------------
    Copyright (c) 2016-25 The Souffle Developers.
    BANNER
    """)

    File.chmod!(path, 0o755)
  end

  # `fun` in the peer, with `dir` first on its PATH.
  defp with_path(peer, dir, fun) do
    Peer.run(peer, fn ->
      original = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> original)

      try do
        fun.()
      after
        System.put_env("PATH", original)
      end
    end)
  end

  # `fun` in a fresh VM — one that has asked no solver, as a run starts —
  # with `dir` first on its PATH.
  defp fresh_with_path(dir, fun) do
    peer = Peer.start!()

    try do
      with_path(peer, dir, fun)
    after
      :peer.stop(peer)
    end
  end

  describe "rules/2" do
    test "moves when the solver's version or word size does", %{tmp_dir: dir} do
      fake_souffle!(dir, "2.5")
      old = fresh_with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)

      fake_souffle!(dir, "2.6")
      new = fresh_with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)
      assert old.mailbox != new.mailbox
      assert old.stage0 != new.stage0

      fake_souffle!(dir, "2.6", 32)
      assert fresh_with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end) != new
    end

    @tag :souffle
    test "keeps what each program loads, and the solver's version, in the store", %{
      tmp_dir: dir
    } do
      store = Path.join(dir, "store")
      programs = Path.join(store, "programs")
      peer = Peer.start!()

      {kept, bare} =
        Peer.run(peer, fn ->
          {Scry.Fingerprint.rules([:mailbox], cache: store), Scry.Fingerprint.rules([:mailbox])}
        end)

      assert kept == bare

      names = File.ls!(programs)

      for program <- ~w(mailbox stage0 points_to),
          do: assert(Enum.any?(names, &String.starts_with?(&1, program <> "-")))

      # --force asks again: a stamp names the solver's file, not what it
      # runs.
      planted = Path.join(programs, "planted-" <> String.duplicate("0", 64))
      File.write!(planted, "")

      assert Peer.run(peer, fn ->
               Scry.Fingerprint.rules([:mailbox], cache: store, refresh: true)
             end) == bare

      refute File.exists?(planted)
    end
  end

  describe "souffle_version/0 (deprecated)" do
    setup do
      %{peer: Peer.start!()}
    end

    # Deprecated: called through apply so the suite compiles clean.
    defp souffle_version, do: apply(Scry.Fingerprint, :souffle_version, [])

    test "records the solver's version, not the banner's rule", %{tmp_dir: dir, peer: peer} do
      fake_souffle!(dir, "2.5")
      assert with_path(peer, dir, &souffle_version/0) == "2.5 (64-bit words)"
    end

    test "fingerprints an unfamiliar banner whole", %{tmp_dir: dir, peer: peer} do
      path = Path.join(dir, "souffle")
      File.write!(path, "#!/bin/sh\necho 'souffle nightly abc123'\n")
      File.chmod!(path, 0o755)
      nightly = with_path(peer, dir, &souffle_version/0)

      File.write!(path, "#!/bin/sh\necho 'souffle nightly def456'\n")
      assert nightly =~ "unrecognized:"
      assert with_path(peer, dir, &souffle_version/0) != nightly
    end

    test "is unknown without a solver", %{tmp_dir: dir, peer: peer} do
      # PATH narrowed to a directory with no souffle in it.
      Peer.run(peer, fn ->
        System.put_env("PATH", dir)
        assert souffle_version() == "unknown"
      end)
    end
  end

  describe "program_digest/2" do
    # analyses/a.dl → ../lib/shared.dl → deep.dl; analyses/b.dl stands
    # alone; lib/unrelated.dl is included by nothing.
    defp rules_tree!(dir) do
      File.mkdir_p!(Path.join(dir, "analyses"))
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "analyses/a.dl"),
        ~s(.include "../lib/shared.dl"\n.decl a\(x: symbol\)\n.output a\na\(x\) :- s\(x\).\n)
      )

      File.write!(Path.join(dir, "analyses/b.dl"), ".decl b(x: symbol)\n.output b\nb(\"b\").\n")

      File.write!(
        Path.join(dir, "lib/shared.dl"),
        ~s(  .include "deep.dl"\n.decl s\(x: symbol\)\ns\(x\) :- d\(x\).\n)
      )

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol)\nd(\"d\").\n")
      File.write!(Path.join(dir, "lib/unrelated.dl"), ".decl u(x: symbol)\n")
    end

    defp digests(dir) do
      {Scry.Fingerprint.program_digest(Path.join(dir, "analyses/a.dl")),
       Scry.Fingerprint.program_digest(Path.join(dir, "analyses/b.dl"))}
    end

    test "moves with a transitively included file, only for its includers", %{tmp_dir: dir} do
      rules_tree!(dir)
      {a, b} = digests(dir)

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol)\nd(\"e\").\n")
      {a2, b2} = digests(dir)
      assert a2 != a
      assert b2 == b

      File.write!(Path.join(dir, "lib/unrelated.dl"), ".decl u(x: number)\n")
      assert digests(dir) == {a2, b2}
    end

    test "a missing include moves the digest when it appears", %{tmp_dir: dir} do
      rules_tree!(dir)
      File.rm!(Path.join(dir, "lib/deep.dl"))
      {missing, _} = digests(dir)

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol)\n")
      assert elem(digests(dir), 0) != missing
    end

    @tag :souffle
    test "counts a file of declarations by the ones the program loads", %{tmp_dir: dir} do
      # As `mix argus.gen.dl` writes one: declarations and comments alone.
      decls = Path.join(dir, "decls.dl")

      File.write!(decls, """
      // Read by the program.
      .decl edge(x: symbol, y: symbol)
      .input edge
      // Declared, never read.
      .decl unread(x: symbol)
      .input unread
      """)

      program = Path.join(dir, "p.dl")

      File.write!(program, """
      .include "decls.dl"
      .decl path(x: symbol, y: symbol)
      .output path
      path(x, y) :- edge(x, y).
      """)

      digest = Scry.Fingerprint.program_digest(program)

      edit = fn from, to ->
        File.write!(decls, String.replace(File.read!(decls), from, to))
        Scry.Fingerprint.program_digest(program)
      end

      # A relation added, one the program does not load changed, prose:
      # Souffle prunes them before it loads anything.
      assert edit.(".input unread\n", ".input unread\n.decl added(y: number)\n.input added\n") ==
               digest

      assert edit.("unread(x: symbol)", "unread(renamed: number)") == digest
      assert edit.("// Read by the program.", "// Read by the program, reworded.") == digest

      # A loaded relation's declaration moves it.
      refute edit.("edge(x: symbol, y: symbol)", "edge(from: symbol, y: symbol)") == digest
    end

    @tag :souffle
    test "over argus's programs, a relation added moves none; a field renamed, its loaders", %{
      tmp_dir: dir
    } do
      File.cp_r!(Path.join(to_string(:code.priv_dir(:panoptes)), "dl"), Path.join(dir, "dl"))
      layer2 = Path.join(dir, "dl/layer2.dl")

      programs =
        [Path.join(dir, "dl/stage0.dl"), Path.join(dir, "dl/points_to.dl")] ++
          Path.wildcard(Path.join(dir, "dl/analyses/*.dl"))

      digests = fn ->
        programs
        |> Task.async_stream(&{&1, Scry.Fingerprint.program_digest(&1)}, timeout: :infinity)
        |> Map.new(fn {:ok, entry} -> entry end)
      end

      loads =
        Map.new(programs, fn program ->
          {:ok, relations} = Argus.Souffle.input_relations(program)
          {program, relations}
        end)

      before = digests.()

      # As `mix argus.gen.dl` writes a relation the schema gained.
      File.write!(
        layer2,
        File.read!(layer2) <>
          "\n// Read by nothing.\n.decl scry_probe(module: symbol)\n.input scry_probe\n"
      )

      assert digests.() == before

      # A layer-2 relation some programs load and others do not, its
      # first field renamed.
      [_ | _] = counts = for {_program, relations} <- loads, relation <- relations, do: relation

      relation =
        counts
        |> Enum.frequencies()
        |> Enum.filter(fn {relation, n} ->
          n < length(programs) and File.read!(layer2) =~ ".decl #{relation}("
        end)
        |> Enum.min()
        |> elem(0)

      File.write!(
        layer2,
        Regex.replace(
          ~r/^\.decl #{relation}\((\w+):/m,
          File.read!(layer2),
          ".decl #{relation}(\\1_renamed:"
        )
      )

      moved = digests.()
      loaders = for {program, relations} <- loads, relation in relations, do: program
      assert loaders != []

      assert Enum.sort(for {program, digest} <- moved, digest != before[program], do: program) ==
               Enum.sort(loaders)
    end

    test "the shipped programs digest, and differ per analysis" do
      digests = Scry.Fingerprint.rules([:mailbox, :coupling])
      assert Map.keys(digests) |> Enum.sort() == [:coupling, :mailbox, :points_to, :stage0]
      assert digests.mailbox != digests.coupling
    end
  end

  describe "code_digest/1" do
    test "moves when a beam's content does", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "Elixir.A.beam"), "one")
      File.write!(Path.join(dir, "Elixir.B.beam"), "two")
      before = Scry.Fingerprint.code_digest(dir)

      File.write!(Path.join(dir, "Elixir.B.beam"), "three")
      assert Scry.Fingerprint.code_digest(dir) != before
    end

    test "a rebuild whose type checker table differs digests the same", %{tmp_dir: dir} do
      # Compiling the same source again beside other code can write a
      # different `ExCk` chunk; the code is the same.
      source = :code.which(Scry.Fingerprint)
      {:ok, _module, chunks} = :beam_lib.all_chunks(source)
      assert List.keymember?(chunks, ~c"ExCk", 0)

      write = fn chunks ->
        {:ok, beam} = :beam_lib.build_module(chunks)
        File.write!(Path.join(dir, "Elixir.Scry.Fingerprint.beam"), beam)
        Scry.Fingerprint.code_digest(dir)
      end

      original = write.(chunks)
      assert write.(List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", "rebuilt"})) == original

      {~c"Code", code} = List.keyfind(chunks, ~c"Code", 0)
      refute write.(List.keyreplace(chunks, ~c"Code", 0, {~c"Code", code <> <<0>>})) == original
    end

    test "argus's code is every argus beam, debug info included" do
      ebin = Path.join(to_string(:code.lib_dir(:panoptes)), "ebin")
      assert Scry.Fingerprint.argus_code() == Scry.Fingerprint.code_digest(ebin, debug_info: true)
      refute Scry.Fingerprint.argus_code() == Scry.Fingerprint.code_digest(ebin)
    end
  end

  describe "argus_code/1 with a cache" do
    # A stamp trusts no beam written within the last two seconds: a
    # build of argus that just finished is waited out.
    defp settled!(ebin) do
      newest =
        ebin
        |> Path.join("*.beam")
        |> Path.wildcard()
        |> Enum.map(&File.stat!(&1, time: :posix).mtime)
        |> Enum.max()

      age = System.os_time(:second) - newest
      if age <= 2, do: Process.sleep((3 - age) * 1_000)
      ebin
    end

    # What a fresh VM — one that has digested nothing — computes.
    defp fresh_argus_code(opts) do
      peer = Peer.start!()

      try do
        Peer.run(peer, fn -> Scry.Fingerprint.argus_code(opts) end)
      after
        :peer.stop(peer)
      end
    end

    test "is kept beside the dependencies' hashes, and read back from there", %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      settled!(Path.join(to_string(:code.lib_dir(:panoptes)), "ebin"))
      whole = Scry.Fingerprint.argus_code()

      assert fresh_argus_code(cache: store) == whole
      ebins = Path.join(store, "ebins")
      assert [kept] = ebins |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "panoptes-"))

      # A fresh VM takes the kept digests as they are, without reading a
      # beam: planted ones show.
      File.write!(Path.join(ebins, kept), :erlang.term_to_binary([{"planted", "digest"}]))
      refute fresh_argus_code(cache: store) == whole
      assert fresh_argus_code([]) == whole
    end
  end

  describe "env/1" do
    test "carries the runtime and scry's code, and nothing of argus's, its schema included" do
      # What every query reads: a schema edit moving it re-ran them all.
      env = Scry.Fingerprint.env()
      assert env.scry_code =~ ~r/^[0-9a-f]{32}$/

      assert Map.keys(env) |> Enum.sort() ==
               [:elixir, :otp, :scry, :scry_code, :specs_environment]
    end

    test "carries the applications the specs are read from, less argus's own beams" do
      # A read of argus's specs is keyed by `:argus_code` where it
      # happens; an argus edit must not move what every query reads.
      assert Scry.Fingerprint.env().specs_environment ==
               Argus.Specs.environment_digest(exclude: [:panoptes])
    end

    test "the applications the scan watches are named by version alone" do
      # Their beams move with every edit; the graph tracks each one.
      assert Scry.Fingerprint.env([:scry]).specs_environment ==
               Argus.Specs.environment_digest(exclude: [:panoptes, :scry])

      refute Scry.Fingerprint.env([:scry]).specs_environment ==
               Scry.Fingerprint.env().specs_environment
    end
  end

  describe "env/2 with a cache" do
    # A dependency outside OTP and Elixir, as Mix builds one: an
    # application directory whose ebin holds its .app file and a beam.
    defp fake_dependency!(dir) do
      ebin = Path.join(dir, "lib/scry_fake_dep/ebin")
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "scry_fake_dep.app"),
        ~s|{application, scry_fake_dep, [{vsn, "0.1.0"}, {modules, [scry_fake_dep]}]}.\n|
      )

      Path.join(ebin, "scry_fake_dep.beam")
    end

    # The dependency's one module, whose one function returns `value`:
    # atoms of one length compile to beams of one size.
    defp fake_beam(value) do
      forms = [
        {:attribute, 1, :module, :scry_fake_dep},
        {:attribute, 1, :export, [value: 0]},
        {:function, 1, :value, 0, [{:clause, 1, [], [], [{:atom, 1, value}]}]}
      ]

      {:ok, :scry_fake_dep, beam} = :compile.forms(forms, [:debug_info])
      beam
    end

    # Written in place (the inode stays) with `mtime`, well outside the
    # two seconds in which argus trusts no stamp.
    defp write_beam!(path, bytes, mtime) do
      File.write!(path, bytes)
      File.touch!(path, mtime)
    end

    # The specs environment a fresh VM — one that has hashed nothing —
    # computes with the dependency on its code path.
    defp fresh_specs_environment(ebin, opts) do
      peer = Peer.start!()

      try do
        Peer.run(peer, fn ->
          true = Code.prepend_path(ebin)
          Scry.Fingerprint.env([], opts).specs_environment
        end)
      after
        :peer.stop(peer)
      end
    end

    test "a dependency beam that changed moves the digest, as it does without one", %{
      tmp_dir: dir
    } do
      beam = fake_dependency!(dir)
      ebin = Path.dirname(beam)
      cache = [cache: Path.join(dir, "store")]
      now = System.os_time(:second)

      write_beam!(beam, fake_beam(:aaaa), now - 100)
      original = fresh_specs_environment(ebin, cache)
      assert File.ls!(Path.join(dir, "store/ebins")) != []
      assert fresh_specs_environment(ebin, cache) == original

      write_beam!(beam, fake_beam(:bbbb), now - 50)
      changed = fresh_specs_environment(ebin, cache)
      refute changed == original
      assert changed == fresh_specs_environment(ebin, [])
    end

    test "a beam rewritten under its old stamp keeps the kept hashes until a refresh", %{
      tmp_dir: dir
    } do
      beam = fake_dependency!(dir)
      ebin = Path.dirname(beam)
      cache = [cache: Path.join(dir, "store")]
      now = System.os_time(:second)

      write_beam!(beam, fake_beam(:aaaa), now - 100)
      %File.Stat{inode: inode, size: size} = File.stat!(beam)
      original = fresh_specs_environment(ebin, cache)

      # Other code, of the same size, in the same file, with its
      # modification time put back: every field of the stamp as it was.
      write_beam!(beam, fake_beam(:bbbb), now - 100)
      assert %File.Stat{inode: ^inode, size: ^size} = File.stat!(beam)
      rewritten = fresh_specs_environment(ebin, [])
      refute rewritten == original

      # The store answers for a stamp it knows without reading the beam:
      # the edge a stamp cannot see, as scry's scan cannot see a beam of
      # the same size and modification time.
      assert fresh_specs_environment(ebin, cache) == original

      # A refresh (`--force`) reads the beams again and keeps what it
      # read for the VMs after it.
      assert fresh_specs_environment(ebin, [refresh: true] ++ cache) == rewritten
      assert fresh_specs_environment(ebin, cache) == rewritten
    end

    test "keeps nothing with argus's stores turned off", %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      peer = Peer.start!()

      # ARGUS_NO_CACHE is read from the environment: VM-wide, so in the peer.
      Peer.run(peer, fn ->
        System.put_env("ARGUS_NO_CACHE", "1")
        Scry.Fingerprint.env([], cache: store)
      end)

      refute File.exists?(store)
    end
  end

  describe "extraction_code/0" do
    test "covers every producer's code but the schema's, and nothing only findings run" do
      {:ok, closure} = Scry.Fingerprint.extraction_closure()
      modules = Enum.map(closure, &elem(&1, 0))
      assert modules == Enum.sort(Enum.uniq(modules))

      for producer <- [:base | Scry.Analysis.all_extractors()] do
        {:ok, reached} = Argus.Cache.Code.closure(producer)
        left_out = for {module, _beam} <- reached -- closure, do: module

        # The schema's modules are data: each query depends on the
        # entries it read of them instead (`Scry.Analysis`'s
        # `schema_read`).
        assert Enum.all?(left_out, &Argus.Cache.Code.schema_module?/1),
               "#{inspect(producer)} runs code the digest leaves out: #{inspect(left_out)}"
      end

      assert Argus.Schema in Enum.map(elem(Argus.Cache.Code.closure(:base), 1), &elem(&1, 0))
      refute Enum.any?(modules, &Argus.Cache.Code.schema_module?/1)

      # What argus runs only to solve and to report: an edit to it
      # extracts nothing.
      outside =
        [Argus.Findings, Argus.Souffle, Argus.Cache.Code, Argus.Cache.Facts] ++
          Argus.Analysis.builtin_analysis_modules()

      assert Enum.filter(outside, &(&1 in modules)) == []
    end

    test "names the closure's code, not all of argus's" do
      digest = Scry.Fingerprint.extraction_code()
      assert digest =~ ~r/^[0-9a-f]{32}$/
      assert Scry.Fingerprint.extraction_code() == digest
      refute digest == Scry.Fingerprint.argus_code()
    end
  end
end
