# One scratch directory per run holds everything the suite writes to the
# temp dir — fixture checkouts, the parity build, peers' own temp dirs,
# and the souffle scratch root scry prunes — so the async modules share
# it with nobody else on the machine (another checkout's suite, an LSP
# session), and a prune elsewhere never takes a directory a solve here
# is reading. Set before any test module loads: `System.tmp_dir!/0`
# reads it on every call.
run_tmp = Path.join(System.tmp_dir!(), "scry_test_#{System.pid()}")
File.rm_rf!(run_tmp)
File.mkdir_p!(run_tmp)
System.put_env("TMPDIR", run_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf(run_tmp) end)

ExUnit.start(capture_log: true, exclude: [:parity])
