defmodule Scry.FingerprintTest do
  # PATH manipulation — never async.
  use ExUnit.Case, async: false

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

  defp with_path(dir, fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original)

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end

  describe "souffle_version/0" do
    test "records the solver's version, not the banner's rule", %{tmp_dir: dir} do
      fake_souffle!(dir, "2.5")

      assert with_path(dir, fn -> Scry.Fingerprint.souffle_version() end) ==
               "2.5 (64-bit words)"
    end

    test "moves when the version or the word size does", %{tmp_dir: dir} do
      fake_souffle!(dir, "2.5")
      old = with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)

      fake_souffle!(dir, "2.6")
      new = with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)
      assert old.mailbox != new.mailbox
      assert old.stage0 != new.stage0

      fake_souffle!(dir, "2.6", 32)
      assert with_path(dir, fn -> Scry.Fingerprint.rules([:mailbox]) end) != new
    end

    test "fingerprints an unfamiliar banner whole", %{tmp_dir: dir} do
      path = Path.join(dir, "souffle")
      File.write!(path, "#!/bin/sh\necho 'souffle nightly abc123'\n")
      File.chmod!(path, 0o755)
      nightly = with_path(dir, fn -> Scry.Fingerprint.souffle_version() end)

      File.write!(path, "#!/bin/sh\necho 'souffle nightly def456'\n")
      assert nightly =~ "unrecognized:"
      assert with_path(dir, fn -> Scry.Fingerprint.souffle_version() end) != nightly
    end

    test "is unknown without a solver", %{tmp_dir: dir} do
      # PATH narrowed to a directory with no souffle in it.
      original = System.get_env("PATH")
      System.put_env("PATH", dir)

      try do
        assert Scry.Fingerprint.souffle_version() == "unknown"
      after
        System.put_env("PATH", original)
      end
    end
  end

  describe "program_digest/1" do
    # analyses/a.dl → ../lib/shared.dl → deep.dl; analyses/b.dl stands
    # alone; lib/unrelated.dl is included by nothing.
    defp rules_tree!(dir) do
      File.mkdir_p!(Path.join(dir, "analyses"))
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "analyses/a.dl"),
        ~s(.include "../lib/shared.dl"\n.decl a\(x: symbol\)\n)
      )

      File.write!(Path.join(dir, "analyses/b.dl"), ".decl b(x: symbol)\n")

      File.write!(
        Path.join(dir, "lib/shared.dl"),
        ~s(  .include "deep.dl"\n.decl s\(x: symbol\)\n)
      )

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol)\n")
      File.write!(Path.join(dir, "lib/unrelated.dl"), ".decl u(x: symbol)\n")
    end

    defp digests(dir) do
      {Scry.Fingerprint.program_digest(Path.join(dir, "analyses/a.dl")),
       Scry.Fingerprint.program_digest(Path.join(dir, "analyses/b.dl"))}
    end

    test "moves with a transitively included file, only for its includers", %{tmp_dir: dir} do
      rules_tree!(dir)
      {a, b} = digests(dir)

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol, y: symbol)\n")
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

      File.write!(Path.join(dir, "lib/deep.dl"), "")
      assert elem(digests(dir), 0) != missing
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

    test "the environment carries the argus and scry code digests" do
      env = Scry.Fingerprint.env()
      assert env.argus_code =~ ~r/^[0-9a-f]{32}$/
      assert env.scry_code =~ ~r/^[0-9a-f]{32}$/
    end

    test "the environment carries the applications the specs are read from" do
      assert Scry.Fingerprint.env().specs_environment == Argus.Specs.environment_digest()
    end

    test "the applications the scan watches are named by version alone" do
      # Their beams move with every edit; the graph tracks each one.
      assert Scry.Fingerprint.env([:scry]).specs_environment ==
               Argus.Specs.environment_digest(exclude: [:scry])

      refute Scry.Fingerprint.env([:scry]).specs_environment ==
               Scry.Fingerprint.env().specs_environment
    end
  end
end
