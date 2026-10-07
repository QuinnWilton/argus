defmodule Argus.Test.FailingEngine do
  @moduledoc """
  The FlowLog toolchain as built, but for one program whose engine exits
  as it starts, logging `injected failure` where a real engine logs (and
  where argus reads an engine's last words back): a solve of that program
  fails as a real engine's crash would, and every other program solves.

  A cache root of the caller's own (`ARGUS_FLOWLOG_DIR`), whose toolchain
  directory links everything to the real one but that engine. The
  variable is VM-wide: a caller runs in a peer (`Argus.Test.Peer`) or in
  a module that is not `async`.
  """

  @doc """
  Runs `fun` with the engine of each of `programs` (paths under argus's
  rules) failing; `stub:` replaces the failing script with one of the
  caller's, given the real engine's path (a proxy that runs it, say).
  """
  @spec with(Path.t() | [Path.t()], (-> result), keyword()) :: result when result: var
  def with(programs, fun, opts \\ []) do
    {:ok, toolchain} = Argus.FlowLog.toolchain(progress: false)
    engines = Argus.FlowLog.Toolchain.engines(toolchain)

    built =
      for program <- List.wrap(programs) do
        {:ok, %{digest: digest, executable: real}} =
          Argus.FlowLog.engine(Argus.Dl.path(program), progress: false)

        {digest, real}
      end

    digests = Enum.map(built, &elem(&1, 0))

    root =
      Path.join(System.tmp_dir!(), "argus_failing_engine_#{System.unique_integer([:positive])}")

    dir = Path.join(root, Path.basename(toolchain.dir))
    File.mkdir_p!(Path.join(dir, "engines"))
    File.chmod!(root, 0o700)

    for entry <- ~w(bin sources target logs crates) do
      File.ln_s!(Path.join(toolchain.dir, entry), Path.join(dir, entry))
    end

    for engine <- File.ls!(engines), engine not in digests do
      File.ln_s!(Path.join(engines, engine), Path.join([dir, "engines", engine]))
    end

    # The stub is installed as the release engine, which a program of
    # either profile runs (`Argus.FlowLog.Program.installed/3`).
    for {digest, real} <- built do
      stub = Path.join([dir, "engines", digest, "engine"])
      File.mkdir_p!(Path.dirname(stub))

      script =
        case Keyword.fetch(opts, :stub) do
          {:ok, make} ->
            make.(real)

          :error ->
            """
            #!/bin/sh
            while [ $# -gt 0 ]; do
              if [ "$1" = "--log" ]; then echo "injected failure" >> "$2"; fi
              shift
            done
            exit 1
            """
        end

      File.write!(stub, script)
      File.chmod!(stub, 0o755)
    end

    original = System.get_env("ARGUS_FLOWLOG_DIR")
    System.put_env("ARGUS_FLOWLOG_DIR", root)
    # Engines kept from before would not run the stub.
    Argus.FlowLog.Pool.close_all()

    try do
      fun.()
    after
      if original,
        do: System.put_env("ARGUS_FLOWLOG_DIR", original),
        else: System.delete_env("ARGUS_FLOWLOG_DIR")

      Argus.FlowLog.Pool.close_all()
      File.rm_rf!(root)
    end
  end

  @doc """
  A stub (for `with/3`'s `stub:`) that runs the real engine at `real`
  behind a proxy on the protocol's descriptors: every commit runs the
  shell `before` hook first and `after_commit` once the engine replied,
  each with `$out` the commit's output directory.
  """
  @spec proxy(Path.t(), String.t(), String.t()) :: String.t()
  def proxy(real, before \\ "", after_commit \\ "") do
    """
    #!/usr/bin/env python3
    import json, os, struct, subprocess, sys
    child_req_r, child_req_w = os.pipe()
    child_rep_r, child_rep_w = os.pipe()
    def setup():
        os.dup2(child_req_r, 3)
        os.dup2(child_rep_w, 4)
    engine = subprocess.Popen([#{inspect(real)}] + sys.argv[1:], preexec_fn=setup, pass_fds=(3, 4))
    os.close(child_req_r)
    os.close(child_rep_w)
    def read_frame(fd):
        header = b""
        while len(header) < 4:
            chunk = os.read(fd, 4 - len(header))
            if not chunk:
                sys.exit(0)
            header += chunk
        (n,) = struct.unpack(">I", header)
        body = b""
        while len(body) < n:
            body += os.read(fd, n - len(body))
        return body
    def write_frame(fd, body):
        os.write(fd, struct.pack(">I", len(body)) + body)
    def hook(script, out):
        if script.strip():
            subprocess.run(["/bin/sh", "-c", script], env=dict(os.environ, out=out), check=True)
    BEFORE = #{inspect(before)}
    AFTER = #{inspect(after_commit)}
    while True:
        request = read_frame(3)
        op = json.loads(request)
        commit = op.get("op") == "commit"
        if commit:
            hook(BEFORE, op["out"])
        write_frame(child_req_w, request)
        reply = read_frame(child_rep_r)
        if commit:
            hook(AFTER, op["out"])
        write_frame(4, reply)
    """
  end
end
