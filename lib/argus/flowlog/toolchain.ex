defmodule Argus.FlowLog.Toolchain do
  @moduledoc """
  The FlowLog toolchain on this machine: Rust, argus's tool built from
  the embedded sources (`Argus.FlowLog.Native`), and the directory every
  engine is built and kept in.

  Everything lives under one cache root (`root/0`), one directory per
  toolchain: `<root>/<key>`, where the key names the sources and the
  Rust compiler that built them. Another argus version, another FlowLog
  revision or an upgraded `rustc` is another directory, so a build never
  mixes artifacts of two toolchains, and two toolchains coexist.

      <root>/<key>/sources/     the unpacked sources
      <root>/<key>/target/      Cargo's build directory, shared by every build
      <root>/<key>/bin/         the installed tool
      <root>/<key>/engines/     one directory per program digest (Argus.FlowLog.Program)
      <root>/<key>/logs/        each build's Cargo output
      <root>/<key>/crates/      a build's generated crate, while it builds

  argus runs what it finds there, so the root must be the user's own:
  owned by them and writable by no one else (`ensure/1` refuses it
  otherwise, `Argus.FlowLog.Toolchain.TrustError`). Every installed file
  is built in a directory of its own and renamed into place, so a run
  racing another (another VM, another terminal) never sees one half
  written, and a build that fails or is interrupted leaves nothing
  behind.

  Building needs `cargo` and `rustc` (1.88 or newer) on `PATH`, or in
  `~/.cargo/bin`; `ARGUS_CARGO` names the `cargo` to use instead, and when
  it is set argus uses no other. The first build
  fetches FlowLog and its dependencies from the network; every later one
  is offline. `mix argus.flowlog build` (or `argus flowlog build`) does
  it ahead of a run.
  """

  require Logger

  alias Argus.FlowLog.Native

  @enforce_keys [:dir, :key, :cargo, :rustc, :rustc_version]
  defstruct [:dir, :key, :cargo, :rustc, :rustc_version]

  @typedoc "A toolchain: its directory, key, and the Rust that builds it."
  @type t :: %__MODULE__{
          dir: Path.t(),
          key: String.t(),
          cargo: Path.t(),
          rustc: Path.t(),
          rustc_version: String.t()
        }

  @typedoc "Why a toolchain is not available."
  @type reason ::
          {:rust_missing, String.t()}
          | {:rust_too_old, String.t(), String.t()}
          | {:untrusted_root, Path.t(), String.t()}
          | {:build_failed, :tool | {:engine, String.t()}, Path.t(), String.t()}

  @min_rustc {1, 88, 0}

  defmodule TrustError do
    @moduledoc "The toolchain's cache root could be written by another user."
    defexception [:path, :detail]

    @impl Exception
    def message(%{path: path, detail: detail}) do
      "refusing the FlowLog toolchain directory #{path}: #{detail}. argus runs the " <>
        "engines it builds there, so the directory must belong to you and be writable " <>
        "by no one else (set ARGUS_FLOWLOG_DIR to another)"
    end
  end

  @doc """
  The cache root: `$ARGUS_FLOWLOG_DIR`, else `$XDG_CACHE_HOME/argus/flowlog`,
  else `~/.cache/argus/flowlog`. Independent of the blob store
  (`ARGUS_CACHE_DIR`, `ARGUS_NO_CACHE`): a run without a cache still
  reuses the toolchain, which is a build product, not an analysis.
  """
  @spec root() :: Path.t()
  def root do
    case System.get_env("ARGUS_FLOWLOG_DIR") do
      dir when dir not in [nil, ""] ->
        Path.expand(dir)

      _ ->
        base =
          case System.get_env("XDG_CACHE_HOME") do
            dir when dir not in [nil, ""] -> dir
            _ -> Path.join(System.user_home!(), ".cache")
          end

        Path.join([base, "argus", "flowlog"])
    end
  end

  @doc "The minimum `rustc` version, as `{major, minor, patch}`."
  @spec min_rustc() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def min_rustc, do: @min_rustc

  @doc """
  The toolchain, its tool built and installed: from the VM's memo when a
  run already found it, else found (and built when missing). The tool is
  built at most once per machine; an engine, once per program
  (`Argus.FlowLog.Program`).
  """
  @spec ensure(keyword()) :: {:ok, t()} | {:error, reason()}
  def ensure(opts \\ []) do
    memo = {__MODULE__, :ensured, root(), System.get_env("PATH"), System.get_env("ARGUS_CARGO")}

    case :persistent_term.get(memo, nil) do
      %__MODULE__{} = toolchain ->
        if File.regular?(tool(toolchain)), do: {:ok, toolchain}, else: ensure_uncached(memo, opts)

      nil ->
        ensure_uncached(memo, opts)
    end
  end

  defp ensure_uncached(memo, opts) do
    with {:ok, rust} <- rust(),
         {:ok, dir} <- toolchain_dir(rust),
         toolchain =
           struct!(__MODULE__, Map.put(rust, :dir, dir) |> Map.put(:key, Path.basename(dir))),
         :ok <- ensure_tool(toolchain, opts) do
      :persistent_term.put(memo, toolchain)
      {:ok, toolchain}
    end
  end

  @doc "Whether a toolchain can be had (found, or built): `ensure/1` succeeding."
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _}, ensure())

  @doc "The installed tool's path."
  @spec tool(t()) :: Path.t()
  def tool(%__MODULE__{dir: dir}), do: Path.join([dir, "bin", "argus-flowlog-tool"])

  @doc "The unpacked sources (the toolchain's key covers their digest)."
  @spec src(t()) :: Path.t()
  def src(%__MODULE__{dir: dir}), do: Path.join([dir, "sources", Native.digest()])

  @doc "Cargo's shared build directory."
  @spec target(t()) :: Path.t()
  def target(%__MODULE__{dir: dir}), do: Path.join(dir, "target")

  @doc "The directory holding every installed engine."
  @spec engines(t()) :: Path.t()
  def engines(%__MODULE__{dir: dir}), do: Path.join(dir, "engines")

  @doc "The directory scratch crates are generated in (one per build, removed after)."
  @spec tmp(t()) :: Path.t()
  def tmp(%__MODULE__{dir: dir}), do: Path.join(dir, "crates")

  @doc "Where the build of the engine for `digest` keeps Cargo's output."
  @spec build_log(t(), String.t()) :: Path.t()
  def build_log(toolchain, digest), do: Path.join(logs(toolchain), "build-#{digest}.log")

  @doc "Where a running engine for `digest` logs (its standard output and error)."
  @spec run_log(t(), String.t()) :: Path.t()
  def run_log(toolchain, digest), do: Path.join(logs(toolchain), "run-#{digest}.log")

  @doc "The directory holding build logs."
  @spec logs(t()) :: Path.t()
  def logs(%__MODULE__{dir: dir}), do: Path.join(dir, "logs")

  # ── Rust ─────────────────────────────────────────────────────────────

  @typedoc "`cargo` and `rustc`, with `rustc`'s verbose version."
  @type rust :: %{cargo: Path.t(), rustc: Path.t(), rustc_version: String.t()}

  @doc """
  `cargo` and `rustc` (`t:rust/0`), or why they cannot build the toolchain.
  """
  @spec rust() :: {:ok, rust()} | {:error, reason()}
  def rust do
    with {:ok, cargo} <- find_cargo(),
         {:ok, rustc} <- find_rustc(cargo),
         {:ok, version} <- rustc_version(rustc) do
      {:ok, %{cargo: cargo, rustc: rustc, rustc_version: version}}
    end
  end

  # `ARGUS_CARGO`, when set, is the only cargo argus uses: one a user
  # named and argus could not run is an error, never a reason to build
  # with another.
  defp find_cargo do
    case System.get_env("ARGUS_CARGO") do
      named when named not in [nil, ""] ->
        if executable?(named),
          do: {:ok, named},
          else:
            {:error, {:rust_missing, "ARGUS_CARGO names #{named}, which is not an executable"}}

      _ ->
        case Enum.find(
               [System.find_executable("cargo"), home_bin("cargo")],
               &(&1 && executable?(&1))
             ) do
          nil -> {:error, {:rust_missing, "cargo was not found on PATH or in ~/.cargo/bin"}}
          cargo -> {:ok, cargo}
        end
    end
  end

  # The rustc beside cargo first: a rustup proxy pair agrees on the
  # toolchain it selects.
  defp find_rustc(cargo) do
    candidates =
      [
        Path.join(Path.dirname(cargo), "rustc"),
        System.find_executable("rustc"),
        home_bin("rustc")
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find(candidates, &executable?/1) do
      nil -> {:error, {:rust_missing, "rustc was not found beside #{cargo} or on PATH"}}
      rustc -> {:ok, rustc}
    end
  end

  defp home_bin(name) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".cargo", "bin", name])
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp rustc_version(rustc) do
    case System.cmd(rustc, ["-vV"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/^release: (\d+)\.(\d+)\.(\d+)/m, out) do
          [_, major, minor, patch] ->
            found = {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

            if found >= @min_rustc,
              do: {:ok, out},
              else:
                {:error,
                 {:rust_too_old, "#{major}.#{minor}.#{patch}", version_string(@min_rustc)}}

          nil ->
            {:error, {:rust_missing, "#{rustc} -vV printed no release: #{String.trim(out)}"}}
        end

      {out, status} ->
        {:error, {:rust_missing, "#{rustc} -vV exited #{status}: #{String.trim(out)}"}}
    end
  rescue
    error -> {:error, {:rust_missing, "#{rustc} could not run: #{Exception.message(error)}"}}
  end

  defp version_string({a, b, c}), do: "#{a}.#{b}.#{c}"

  # ── The toolchain's directory ────────────────────────────────────────

  # `<root>/<key>`, the key naming the sources and the compiler (the
  # verbose version names its host triple and LLVM too). The root is
  # made by this module alone, owner-only, and refused when another
  # user could write it.
  defp toolchain_dir(rust) do
    key = key(rust)
    root = root()

    with :ok <- trusted_root(root) do
      dir = Path.join(root, key)

      with :ok <- mkdir_owned(dir),
           :ok <- mkdir_owned(Path.join(dir, "bin")),
           :ok <- mkdir_owned(Path.join(dir, "engines")),
           :ok <- mkdir_owned(Path.join(dir, "logs")),
           :ok <- mkdir_owned(Path.join(dir, "crates")),
           :ok <- mkdir_owned(Path.join(dir, "sources")) do
        _ = Native.unpack!(Path.join(dir, "sources"))
        {:ok, dir}
      end
    end
  end

  @doc """
  The name of the toolchain directory `rust` (`rust/0`) builds for these
  sources, under `root/0`; nothing is built.
  """
  @spec key(rust()) :: String.t()
  def key(%{rustc_version: version}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({Native.digest(), version}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  @doc """
  The toolchain directories under `root/0` other than `current`'s (a
  key, or `nil` for all of them): those built for other sources or
  another Rust, which nothing here uses again. Only a directory shaped
  as this module makes one is listed, whatever else the root holds.
  """
  @spec stale(String.t() | nil) :: [Path.t()]
  def stale(current) do
    root = root()

    case File.ls(root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            name != current,
            Regex.match?(~r/\A[0-9a-f]{24}\z/, name),
            dir = Path.join(root, name),
            Enum.all?(~w(engines sources), &File.dir?(Path.join(dir, &1))),
            do: dir

      {:error, _} ->
        []
    end
  end

  defp trusted_root(root) do
    with :ok <- mkdir_owned(root) do
      case check_trust(root) do
        :ok -> :ok
        {:error, detail} -> {:error, {:untrusted_root, root, detail}}
      end
    end
  end

  defp mkdir_owned(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        _ = File.chmod(dir, 0o700)
        :ok

      {:error, reason} ->
        {:error, {:untrusted_root, dir, "cannot create it: #{:file.format_error(reason)}"}}
    end
  end

  @doc false
  @spec check_trust(Path.t()) :: :ok | {:error, String.t()}
  def check_trust(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} ->
        cond do
          uid != current_uid() ->
            {:error, "it belongs to another user (uid #{uid})"}

          Bitwise.band(mode, 0o022) != 0 ->
            {:error,
             "others can write it (mode #{Integer.to_string(Bitwise.band(mode, 0o777), 8)})"}

          true ->
            :ok
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "it is a #{type}, not a directory"}

      {:error, reason} ->
        {:error, "cannot read it: #{:file.format_error(reason)}"}
    end
  end

  defp current_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        {out, 0} = System.cmd("id", ["-u"])
        uid = out |> String.trim() |> String.to_integer()
        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  # ── Building ─────────────────────────────────────────────────────────

  defp ensure_tool(toolchain, opts) do
    if File.regular?(tool(toolchain)) do
      :ok
    else
      locked(:build, fn ->
        if File.regular?(tool(toolchain)), do: :ok, else: build_tool(toolchain, opts)
      end)
    end
  end

  defp build_tool(toolchain, opts) do
    announce(
      opts,
      "building the FlowLog toolchain (once per machine; the first build fetches FlowLog)"
    )

    crate = Path.join(src(toolchain), "tool")

    with :ok <-
           cargo_build(
             toolchain,
             crate,
             ["argus-flowlog-tool"],
             Path.join(logs(toolchain), "tool.log"),
             :tool
           ) do
      install(built(toolchain, "argus-flowlog-tool"), tool(toolchain))
    end
  end

  @doc """
  Builds the binaries `bins` of the crate at `crate` into the toolchain's
  shared target directory (each then at `built/2`): `:ok`, or
  `{:error, {:build_failed, what, log, tail}}` with Cargo's output kept
  at `log`. Uses the crate's lockfile as it stands (`--locked`), and
  goes on past a binary that fails (`--keep-going`), so the others are
  built.

  Cargo runs `build_jobs/0` compiles at once.
  """
  @spec cargo_build(t(), Path.t(), [String.t()], Path.t(), term()) :: :ok | {:error, reason()}
  def cargo_build(toolchain, crate, bins, log, what) do
    args =
      [
        "build",
        "--release",
        "--locked",
        "--keep-going",
        "--jobs",
        Integer.to_string(build_jobs())
      ] ++
        Enum.flat_map(bins, &["--bin", &1]) ++
        ["--manifest-path", Path.join(crate, "Cargo.toml")]

    env = [
      {"CARGO_TARGET_DIR", target(toolchain)},
      {"RUSTC", toolchain.rustc},
      # The build is argus's own: a project's or user's flags are not.
      {"RUSTFLAGS", nil},
      {"CARGO_BUILD_TARGET", nil},
      {"CARGO_ENCODED_RUSTFLAGS", nil},
      {"CARGO_BUILD_JOBS", nil}
    ]

    {output, status} =
      System.cmd(toolchain.cargo, args, env: env, stderr_to_stdout: true, cd: crate)

    File.write!(log, output)

    case status do
      0 -> :ok
      _ -> {:error, {:build_failed, what, log, tail(output)}}
    end
  end

  @doc "Where `cargo_build/5` leaves the binary `bin`."
  @spec built(t(), String.t()) :: Path.t()
  def built(toolchain, bin), do: Path.join([target(toolchain), "release", bin])

  @doc """
  How many compiles a build runs at once: `ARGUS_FLOWLOG_BUILD_JOBS`, or
  as many as there are cores and, at 4 GB each, memory for. A large
  program's compile holds gigabytes (argus's largest peaks near 7 GB),
  and a dozen side by side on a laptop would swap rather than finish.
  """
  @spec build_jobs() :: pos_integer()
  def build_jobs do
    case Integer.parse(System.get_env("ARGUS_FLOWLOG_BUILD_JOBS", "")) do
      {n, ""} when n > 0 ->
        n

      _ ->
        cores = System.schedulers_online()

        case memory_bytes() do
          {:ok, bytes} -> max(1, min(cores, div(bytes, 4_000_000_000)))
          :error -> max(1, div(cores, 2))
        end
    end
  end

  defp memory_bytes do
    case :os.type() do
      {:unix, :darwin} ->
        with {out, 0} <- System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true),
             {bytes, _} <- Integer.parse(String.trim(out)),
             do: {:ok, bytes},
             else: (_ -> :error)

      {:unix, :linux} ->
        with {:ok, info} <- File.read("/proc/meminfo"),
             [_, kb] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, info),
             do: {:ok, String.to_integer(kb) * 1024},
             else: (_ -> :error)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp tail(output) do
    lines = String.split(output, "\n")
    errors = Enum.filter(lines, &String.starts_with?(&1, "error"))
    shown = if errors == [], do: Enum.take(lines, -15), else: Enum.take(errors, 10)
    Enum.join(shown, "\n")
  end

  @doc """
  Installs `built` at `dest`: copied beside it and renamed into place, so
  a reader sees the whole executable or none.
  """
  @spec install(Path.t(), Path.t()) :: :ok
  def install(built, dest) do
    staging = "#{dest}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    try do
      File.cp!(built, staging)
      File.chmod!(staging, 0o700)
      File.rename!(staging, dest)
    after
      File.rm(staging)
    end
  end

  @doc """
  Runs `fun` holding the VM's lock on `key`. Every build takes `:build`:
  compiling a large program's engine takes gigabytes of memory, so a VM
  builds one thing at a time. Builds in other VMs are serialized by
  Cargo's own lock on the target directory, and installs are atomic
  renames.
  """
  @spec locked(term(), (-> result)) :: result when result: var
  def locked(key, fun), do: :global.trans({{__MODULE__, key}, self()}, fun, [node()], :infinity)

  @doc """
  Tells the caller's `:progress` function (default `Logger.info/1`) of
  `message`, prefixed `argus: `; `progress: false` says nothing.
  """
  @spec announce(keyword(), String.t()) :: :ok
  def announce(opts, message) do
    case Keyword.get(opts, :progress, &Logger.info/1) do
      false ->
        :ok

      fun ->
        _ = fun.("argus: " <> message)
        :ok
    end
  end

  @doc """
  A sentence for a user saying why the toolchain is unavailable and what
  to do about it.
  """
  @spec describe(reason()) :: String.t()
  def describe({:rust_missing, detail}) do
    "argus runs its analyses on FlowLog engines it builds with Rust, and " <>
      "#{detail}. Install Rust (https://rustup.rs), or set ARGUS_CARGO to a cargo, then " <>
      "run `mix argus.flowlog build`."
  end

  def describe({:rust_too_old, found, needed}) do
    "argus builds its FlowLog engines with Rust #{needed} or newer, and found #{found}. " <>
      "Run `rustup update stable` (or set ARGUS_CARGO to a newer cargo)."
  end

  def describe({:untrusted_root, path, detail}) do
    Exception.message(%TrustError{path: path, detail: detail})
  end

  def describe({:build_failed, what, log, tail}) do
    subject =
      case what do
        :tool -> "the FlowLog toolchain"
        {:engine, program} -> "the FlowLog engine for #{program}"
        {:engines, count} -> "#{count} FlowLog engines"
      end

    "building #{subject} failed (the full Cargo output is at #{log}):\n#{tail}"
  end
end
