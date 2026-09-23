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

  describe "env/1 souffle entry" do
    test "records the solver's version, not the banner's rule", %{tmp_dir: dir} do
      fake_souffle!(dir, "2.5")

      assert with_path(dir, fn -> Scry.Fingerprint.env(true).souffle end) ==
               "2.5 (64-bit words)"
    end

    test "moves when the version or the word size does", %{tmp_dir: dir} do
      fake_souffle!(dir, "2.5")
      old = with_path(dir, fn -> Scry.Fingerprint.env(true) end)

      fake_souffle!(dir, "2.6")
      new = with_path(dir, fn -> Scry.Fingerprint.env(true) end)
      assert old != new

      fake_souffle!(dir, "2.6", 32)
      assert with_path(dir, fn -> Scry.Fingerprint.env(true) end) != new
    end

    test "fingerprints an unfamiliar banner whole", %{tmp_dir: dir} do
      path = Path.join(dir, "souffle")
      File.write!(path, "#!/bin/sh\necho 'souffle nightly abc123'\n")
      File.chmod!(path, 0o755)
      nightly = with_path(dir, fn -> Scry.Fingerprint.env(true).souffle end)

      File.write!(path, "#!/bin/sh\necho 'souffle nightly def456'\n")
      assert nightly =~ "unrecognized:"
      assert with_path(dir, fn -> Scry.Fingerprint.env(true).souffle end) != nightly
    end

    test "is nil without a solver" do
      assert Scry.Fingerprint.env(false).souffle == nil
    end
  end
end
