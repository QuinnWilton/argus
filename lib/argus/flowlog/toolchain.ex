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
  alias Argus.FlowLog.Prebuilt

  @enforce_keys [:dir, :key, :kind, :cargo, :rustc, :rustc_version]
  defstruct [:dir, :key, :kind, :cargo, :rustc, :rustc_version]

  @typedoc """
  A toolchain: its directory, key, and the Rust that builds its engines
  (`:rust`), or none (`:prebuilt`: the tool and the built-in programs'
  engines come from a release's bundle, `Argus.FlowLog.Prebuilt`, and no
  other engine can be built).
  """
  @type t :: %__MODULE__{
          dir: Path.t(),
          key: String.t(),
          kind: :rust | :prebuilt,
          cargo: Path.t() | nil,
          rustc: Path.t() | nil,
          rustc_version: String.t() | nil
        }

  @typedoc "Why a toolchain is not available."
  @type reason ::
          {:rust_missing, String.t()}
          | {:rust_too_old, String.t(), String.t()}
          | {:untrusted_root, Path.t(), String.t()}
          | {:unwritable_root, Path.t(), String.t()}
          | {:build_failed, :tool | {:engine, String.t()} | {:engines, pos_integer()}, Path.t(),
             String.t()}
          | {:needs_rust, String.t()}
          | {:no_engines, rust_reason :: reason(), Prebuilt.reason()}

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
        Path.join([Argus.Dirs.cache_home(), "argus", "flowlog"])
    end
  end

  @doc """
  The toolchain, its tool built and installed: from the VM's memo when a
  run already found it, else found (and built when missing). The tool is
  built at most once per machine; an engine, once per program
  (`Argus.FlowLog.Program`).

  A build of the tool that fails is not tried again by the same VM (each
  analysis of a run asks), until `forget_failures/0`.
  """
  @spec ensure(keyword()) :: {:ok, t()} | {:error, reason()}
  def ensure(opts \\ []) do
    memo = {__MODULE__, :ensured, root(), System.get_env("PATH"), System.get_env("ARGUS_CARGO")}

    case :persistent_term.get(memo, nil) do
      %__MODULE__{} = toolchain ->
        if File.regular?(tool(toolchain)), do: {:ok, toolchain}, else: ensure_uncached(memo, opts)

      {:failed, reason} ->
        {:error, reason}

      nil ->
        ensure_uncached(memo, opts)
    end
  end

  @doc "Forgets the builds of the tool this VM saw fail, so the next `ensure/1` tries again."
  @spec forget_failures() :: :ok
  def forget_failures do
    for {{__MODULE__, :ensured, _, _, _} = memo, {:failed, _}} <- :persistent_term.get(),
        do: :persistent_term.erase(memo)

    :ok
  end

  # With Rust, a toolchain that builds; without it (or with one too old),
  # the release's bundle when there is one for this machine, and the
  # reason Rust is needed when there is not.
  defp ensure_uncached(memo, opts) do
    result =
      case rust() do
        {:ok, rust} ->
          with {:ok, dir} <- toolchain_dir(key(rust)) do
            toolchain =
              struct!(__MODULE__, Map.merge(rust, %{dir: dir, key: key(rust), kind: :rust}))

            discard_unrunnable(toolchain)
            with :ok <- ensure_tool(toolchain, memo, opts), do: {:ok, toolchain}
          end

        {:error, rust_reason} ->
          prebuilt(rust_reason, opts)
      end

    with {:ok, toolchain} <- result do
      :persistent_term.put(memo, toolchain)
      {:ok, toolchain}
    end
  end

  defp prebuilt(rust_reason, opts) do
    with {:ok, bundle} <- Prebuilt.fetch(opts),
         {:ok, bundled} <- Prebuilt.tool(bundle),
         {:ok, key} <- prebuilt_key(),
         {:ok, dir} <- toolchain_dir(key) do
      toolchain = %__MODULE__{
        dir: dir,
        key: key,
        kind: :prebuilt,
        cargo: nil,
        rustc: nil,
        rustc_version: nil
      }

      discard_unrunnable(toolchain)
      unless File.regular?(tool(toolchain)), do: install(bundled, tool(toolchain))
      {:ok, toolchain}
    else
      {:error, {tag, _, _}} = error when tag in [:untrusted_root, :unwritable_root] -> error
      {:error, prebuilt_reason} -> {:error, {:no_engines, rust_reason, prebuilt_reason}}
      :error -> {:error, {:no_engines, rust_reason, {:bad_bundle, "it holds no tool"}}}
    end
  end

  # A tool that does not run here (an executable built for another
  # system, installed from a release's bundle, or one whose libraries
  # have since gone, as a NixOS garbage collection removes them) goes,
  # with the engines beside it: none of them runs either, and none was
  # built by this tool, which could not have generated it. A run then
  # installs or builds them again.
  defp discard_unrunnable(toolchain) do
    path = tool(toolchain)

    with true <- File.regular?(path),
         {:error, detail} <- runs(path) do
      Logger.warning(
        "argus: the FlowLog tool at #{path} does not run on this machine (#{detail}); " <>
          "replacing it, and the engines installed beside it"
      )

      File.rm!(path)
      File.rm_rf!(engines(toolchain))
      :ok = mkdir_owned(engines(toolchain))
    end

    :ok
  end

  @doc """
  Whether the tool at `path` runs on this machine: `:ok`, or
  `{:error, detail}` saying what happened when it was run. Run without
  arguments, the tool prints its usage and exits 2; an executable this
  system cannot load fails before it gets that far (NixOS's stub loader
  exits 127 for one linked for other Linux distributions).
  """
  @spec runs(Path.t()) :: :ok | {:error, String.t()}
  def runs(path) do
    with {:error, detail} <- run_bare(path) do
      case missing_loader(path) do
        nil -> {:error, detail}
        loader -> {:error, "its dynamic loader, #{loader}, is not on this system"}
      end
    end
  end

  defp run_bare(path) do
    case System.cmd(path, [], stderr_to_stdout: true) do
      {out, 2} ->
        if out =~ "usage: argus-flowlog-tool",
          do: :ok,
          else: {:error, "it exited 2 without printing its usage: #{first_line(out)}"}

      {out, status} ->
        case glibc_needed(out) do
          nil -> {:error, "it exited #{status}: #{first_line(out)}"}
          version -> {:error, "it needs glibc #{version} or newer, and this system's is older"}
        end
    end
  rescue
    # Only what says the file cannot be executed here: any other failure
    # to start it (out of file descriptors, say) says nothing about the
    # tool, and must not have it, and the engines beside it, discarded.
    error in ErlangError ->
      if error.original in [:enoexec, :eacces, :enoent],
        do: {:error, "it could not be run: #{:file.format_error(error.original)}"},
        else: reraise(error, __STACKTRACE__)
  end

  # The dynamic loader a 64-bit little-endian ELF executable names
  # (its PT_INTERP), when this system has no file there: what NixOS lacks
  # for a binary linked for other Linux distributions. Read from the
  # file's first 64 KB, where the program headers and the path are.
  defp missing_loader(path) do
    with {:ok, head} <- read_head(path, 65_536),
         <<0x7F, "ELF", 2, 1, _::binary-size(26), phoff::little-64, _::binary-size(14),
           phentsize::little-16, phnum::little-16, _::binary>> <- head,
         loader when is_binary(loader) <- interp(head, phoff, phentsize, phnum),
         false <- File.exists?(loader) do
      loader
    else
      _ -> nil
    end
  end

  defp interp(head, phoff, phentsize, phnum) do
    Enum.find_value(0..(phnum - 1)//1, fn i ->
      case binary_slice(head, phoff + i * phentsize, 40) do
        <<3::little-32, _flags::32, offset::little-64, _vaddr::64, _paddr::64, size::little-64>> ->
          head |> binary_slice(offset, size) |> String.trim_trailing(<<0>>)

        _ ->
          nil
      end
    end)
  end

  defp read_head(path, bytes) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, bytes) do
        data when is_binary(data) -> data
        _ -> ""
      end
    end)
  end

  # The newest glibc the dynamic loader says is missing ("version
  # `GLIBC_2.34' not found", a line per version), or nil.
  defp glibc_needed(out) do
    case Regex.scan(~r/`GLIBC_(\d+(?:\.\d+)*)' not found/, out, capture: :all_but_first) do
      [] -> nil
      found -> found |> List.flatten() |> Enum.max_by(&version_parts/1)
    end
  end

  defp version_parts(version),
    do: version |> String.split(".") |> Enum.map(&String.to_integer/1)

  defp first_line(out) do
    case out |> String.trim() |> String.split("\n", parts: 2) do
      [""] -> "no output"
      [line | _] -> line
    end
  end

  # A toolchain without Rust is named for its sources and its platform.
  defp prebuilt_key do
    with {:ok, triple} <- Prebuilt.platform() do
      {:ok,
       :crypto.hash(:sha256, :erlang.term_to_binary({Native.digest(), :prebuilt, triple}))
       |> Base.encode16(case: :lower)
       |> binary_part(0, 24)}
    end
  end

  @doc """
  The key of the toolchain this machine uses (`ensure/1`'s), computed
  without building or downloading anything; `nil` when it has none.
  """
  @spec current_key() :: String.t() | nil
  def current_key do
    case rust() do
      {:ok, rust} ->
        key(rust)

      {:error, _} ->
        case prebuilt_key() do
          {:ok, key} -> key
          {:error, _} -> nil
        end
    end
  end

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

  Found once per VM for a `PATH`, `ARGUS_CARGO` and home, as `ensure/1`
  keeps the toolchain: every run asks, and finding them is a search of
  the `PATH` and a run of `rustc`. A search that finds none is not kept,
  so a Rust installed while the VM runs is found.
  """
  @spec rust() :: {:ok, rust()} | {:error, reason()}
  def rust do
    memo =
      {__MODULE__, :rust, System.get_env("PATH"), System.get_env("ARGUS_CARGO"),
       System.user_home()}

    case :persistent_term.get(memo, nil) do
      {:ok, _rust} = found ->
        found

      nil ->
        with {:ok, _rust} = found <- find_rust() do
          :persistent_term.put(memo, found)
          found
        end
    end
  end

  defp find_rust do
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
    case Argus.RawFile.stat(path) do
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
  defp toolchain_dir(key) do
    with {:ok, dir} <- owned_dir(key),
         :ok <- mkdir_owned(Path.join(dir, "bin")),
         :ok <- mkdir_owned(Path.join(dir, "engines")),
         :ok <- mkdir_owned(Path.join(dir, "logs")),
         :ok <- mkdir_owned(Path.join(dir, "crates")),
         :ok <- mkdir_owned(Path.join(dir, "sources")) do
      _ = Native.unpack!(Path.join(dir, "sources"))
      {:ok, dir}
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

  @doc """
  `<root>/<name>` (`root/0`), created owner-only: `{:ok, dir}` once the
  root and the directory are trusted (`check_trust/1`), or
  `{:error, {:untrusted_root, path, detail}}`, or
  `{:error, {:unwritable_root, path, detail}}` when it cannot be made.
  argus runs what it finds under the root, so nothing there is read or
  run before this.
  """
  @spec owned_dir(String.t()) :: {:ok, Path.t()} | {:error, reason()}
  def owned_dir(name) do
    root = root()
    dir = Path.join(root, name)

    with :ok <- trusted_root(root),
         :ok <- mkdir_owned(dir) do
      case check_trust(dir) do
        :ok -> {:ok, dir}
        {:error, detail} -> {:error, {:untrusted_root, dir, detail}}
      end
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
        {:error, {:unwritable_root, dir, :file.format_error(reason) |> to_string()}}
    end
  end

  @doc false
  @spec check_trust(Path.t()) :: :ok | {:error, String.t()}
  def check_trust(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} ->
        cond do
          uid != Argus.Dirs.uid() ->
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

  # ── Building ─────────────────────────────────────────────────────────

  defp remember_failure(memo, {:error, reason} = error) do
    :persistent_term.put(memo, {:failed, reason})
    error
  end

  defp remember_failure(_memo, :ok), do: :ok

  # Under the lock, a build another process of this VM saw fail while
  # this one waited is that failure, not another build.
  defp ensure_tool(toolchain, memo, opts) do
    if File.regular?(tool(toolchain)) do
      :ok
    else
      locked(:build, fn ->
        case :persistent_term.get(memo, nil) do
          {:failed, reason} ->
            {:error, reason}

          _ ->
            cond do
              File.regular?(tool(toolchain)) -> :ok
              bundled_tool(toolchain, opts) == :ok -> :ok
              true -> remember_failure(memo, build_tool(toolchain, opts))
            end
        end
      end)
    end
  end

  # The release's tool, when the package offers a bundle: what building
  # the tool would make, without the minutes of building it.
  defp bundled_tool(toolchain, opts) do
    with {:ok, bundle} <- Prebuilt.fetch(opts),
         {:ok, bundled} <- Prebuilt.tool(bundle) do
      install(bundled, tool(toolchain))
    else
      {:error, reason} when reason not in [:disabled, :none] ->
        Logger.warning(
          "argus: building the FlowLog toolchain instead: " <>
            Prebuilt.describe(reason)
        )

        :error

      _ ->
        :error
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

  # Runs the command it is given, and stops it, with the compilers it
  # started, when its standard input closes: the BEAM holds that pipe open
  # for as long as the port lives, so a VM that exits or is killed mid-build
  # does not leave Cargo and its rustc processes compiling. The watcher
  # reads a copy of standard input, as a background job's own is /dev/null.
  @guard """
  exec 3<&0
  "$@" </dev/null &
  child=$!
  ( while read -r _ <&3; do :; done
    pkill -TERM -P "$child" 2>/dev/null
    kill -TERM "$child" 2>/dev/null ) &
  watcher=$!
  wait "$child"
  status=$?
  kill "$watcher" 2>/dev/null
  exit "$status"
  """

  @doc """
  Builds the binaries `bins` of the crate at `crate` into the toolchain's
  shared target directory (each then at `built/3`): `:ok`, or
  `{:error, {:build_failed, what, log, tail}}` with Cargo's output kept
  at `log`. Uses the crate's lockfile as it stands (`--locked`), and
  goes on past a binary that fails (`--keep-going`), so the others are
  built. Offline (`Argus.Offline`), Cargo fetches nothing (`--offline`):
  the build uses the crates `~/.cargo` already holds.

  `profile` is the Cargo profile, `:release` or the engine template's
  `:quick`. Cargo runs `build_jobs/0` compiles at once, and stops, with
  them, when this VM does.
  """
  @spec cargo_build(t(), Path.t(), [String.t()], Path.t(), term(), :release | :quick) ::
          :ok | {:error, reason()}
  def cargo_build(toolchain, crate, bins, log, what, profile \\ :release) do
    args =
      [
        "build",
        "--profile",
        Atom.to_string(profile),
        "--locked",
        "--keep-going",
        "--jobs",
        Integer.to_string(build_jobs())
      ] ++
        if(Argus.Offline.offline?(), do: ["--offline"], else: []) ++
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
      System.cmd("/bin/sh", ["-c", @guard, "argus-cargo", toolchain.cargo | args],
        env: env,
        stderr_to_stdout: true,
        cd: crate
      )

    File.write!(log, output)

    case status do
      0 -> :ok
      _ -> {:error, {:build_failed, what, log, tail(output)}}
    end
  end

  @doc "Where `cargo_build/6` leaves the binary `bin` it built with `profile`."
  @spec built(t(), String.t(), :release | :quick) :: Path.t()
  def built(toolchain, bin, profile \\ :release),
    do: Path.join([target(toolchain), Atom.to_string(profile), bin])

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

  # Cargo's errors, the causes first: a missing linker fails every build
  # script, and its one line would drown under a "could not compile" per
  # crate.
  defp tail(output) do
    lines = String.split(output, "\n")
    errors = Enum.filter(lines, &String.starts_with?(&1, "error"))

    {consequences, causes} =
      Enum.split_with(errors, &String.starts_with?(&1, "error: could not compile"))

    shown =
      case {causes, consequences} do
        {[], []} -> Enum.take(lines, -15)
        {[], _} -> Enum.take(consequences, 10)
        {_, []} -> Enum.take(causes, 10)
        _ -> Enum.take(causes, 10) ++ ["(and #{length(consequences)} crate(s) could not compile)"]
      end

    Enum.join(shown ++ hints(output), "\n")
  end

  defp hints(output) do
    if output =~ ~r/linker `[^`]+` not found/,
      do: [
        "Rust needs a C compiler to link with: install gcc or clang (on NixOS, " <>
          "`nix-shell -p cargo rustc gcc`; on Debian or Ubuntu, build-essential)."
      ],
      else: []
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

  def describe({:unwritable_root, path, detail}) do
    "argus keeps its FlowLog engines in #{path}, and cannot create it (#{detail}): set " <>
      "ARGUS_FLOWLOG_DIR to a directory you can write"
  end

  def describe({:no_engines, rust_reason, prebuilt_reason}) do
    if Prebuilt.offered?(prebuilt_reason) do
      # The bundle is what this machine was meant to use: what kept it
      # from it comes first, and Rust only as the other way.
      "argus runs its analyses on FlowLog engines, and could not use the prebuilt ones " <>
        "its release publishes: #{Prebuilt.describe(prebuilt_reason)}. Without them, it " <>
        "builds its own with Rust #{version_string(@min_rustc)} or newer, and " <>
        "#{rust_problem(rust_reason)}: install it from https://rustup.rs, or set ARGUS_CARGO " <>
        "to a cargo."
    else
      describe(rust_reason) <>
        " argus's prebuilt engines are no help either: " <>
        Prebuilt.describe(prebuilt_reason) <> "."
    end
  end

  def describe({:needs_rust, program}) do
    "#{program} needs an engine compiled for it (argus publishes none prebuilt for it, and " <>
      "the generic engine does not run it, or ARGUS_FLOWLOG_ENGINE=compiled asks for one), " <>
      "and building it needs Rust #{version_string(@min_rustc)} or newer: install it from " <>
      "https://rustup.rs (or name its cargo with ARGUS_CARGO)"
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

  defp rust_problem({:rust_missing, detail}), do: detail
  defp rust_problem({:rust_too_old, found, _needed}), do: "found Rust #{found}"
  defp rust_problem(reason), do: describe(reason)
end
