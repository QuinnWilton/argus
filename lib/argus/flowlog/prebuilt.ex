defmodule Argus.FlowLog.Prebuilt do
  @moduledoc """
  Engines built ahead of time for argus's own programs, published with
  each release: one bundle per platform, holding the tool and the engine
  of every built-in program, named in the package with its SHA-256
  (`priv/flowlog/prebuilt.json`, compiled into this module so an escript
  has it too). A machine without Rust runs the built-in analyses from a
  bundle, and one with Rust skips building them; a program of a user's
  own is always built (`Argus.FlowLog.Program`).

  A bundle is used only when everything about it checks out:

    * the package names one for this platform, built from these
      toolchain sources (`Argus.FlowLog.Native.digest/0`);
    * the file's SHA-256 is the one the package names, checked before
      anything in it is unpacked;
    * it holds only regular files where a bundle keeps them: its
      `bundle.json`, the tool at `bin/`, and each engine and its manifest
      at `engines/<digest>/`;
    * its `bundle.json` names the same sources and platform.

  An engine is found by its program's digest, which argus computes for
  itself (`Argus.FlowLog.program_digest/2`): a bundle's engine for
  another version of a program is never used, and `Argus.FlowLog.Engine`
  refuses one that answers for another digest. When a bundle is
  unavailable or fails a check, argus builds the engine with Rust, or
  without it says why it cannot.

  `ARGUS_FLOWLOG_PREBUILT=0` turns bundles off: argus downloads nothing.
  A bundle is unpacked once per machine, under the cache root's
  `prebuilt/<sha256>/`.
  """

  require Logger

  alias Argus.FlowLog.Native
  alias Argus.FlowLog.Toolchain

  @manifest_path Path.expand("../../../priv/flowlog/prebuilt.json", __DIR__)
  @external_resource @manifest_path
  @manifest (case File.read(@manifest_path) do
               {:ok, text} -> :json.decode(text)
               {:error, :enoent} -> nil
             end)

  @format 1
  @digest ~r/\A[0-9a-f]{64}\z/

  @typedoc "A bundle the package offers for this platform."
  @type offer :: %{url: String.t(), sha256: String.t(), bytes: non_neg_integer()}

  @typedoc "Why no bundle is used."
  @type reason ::
          :disabled
          | :none
          | {:unsupported_platform, String.t()}
          | {:no_bundle, String.t()}
          | {:other_sources, String.t()}
          | {:download_failed, String.t(), term()}
          | {:checksum_mismatch, String.t(), String.t()}
          | {:bad_bundle, String.t()}

  @doc """
  The platform a bundle must be built for, as a Rust target triple:
  `{:ok, triple}`, or `{:error, {:unsupported_platform, architecture}}`
  for one no bundle is built for.
  """
  @spec platform() :: {:ok, String.t()} | {:error, reason()}
  def platform do
    arch = to_string(:erlang.system_info(:system_architecture))

    cond do
      arch =~ ~r/\Aaarch64-apple-darwin/ -> {:ok, "aarch64-apple-darwin"}
      arch =~ ~r/\Ax86_64-apple-darwin/ -> {:ok, "x86_64-apple-darwin"}
      arch =~ ~r/\Ax86_64-.*-linux-gnu/ -> {:ok, "x86_64-unknown-linux-gnu"}
      arch =~ ~r/\Aaarch64-.*-linux-gnu/ -> {:ok, "aarch64-unknown-linux-gnu"}
      true -> {:error, {:unsupported_platform, arch}}
    end
  end

  @doc """
  The bundle the package offers for this platform, or why there is none.
  """
  @spec offer() :: {:ok, offer()} | {:error, reason()}
  def offer do
    with :ok <- enabled(),
         {:ok, manifest} <- manifest(),
         :ok <- same_sources(manifest),
         {:ok, triple} <- platform() do
      case manifest["bundles"] do
        %{^triple => %{"url" => url, "sha256" => sha, "bytes" => bytes}} ->
          {:ok, %{url: url, sha256: String.downcase(sha), bytes: bytes}}

        _ ->
          {:error, {:no_bundle, triple}}
      end
    end
  end

  defp enabled do
    if System.get_env("ARGUS_FLOWLOG_PREBUILT") == "0", do: {:error, :disabled}, else: :ok
  end

  # The package's offer, or a test's (application env), which never
  # widens what is checked.
  defp manifest do
    case Application.get_env(:argus_beam, :flowlog_prebuilt, @manifest) do
      %{"format" => @format} = manifest -> {:ok, manifest}
      _ -> {:error, :none}
    end
  end

  defp same_sources(%{"native" => native}) do
    if native == Native.digest(), do: :ok, else: {:error, {:other_sources, native}}
  end

  defp same_sources(_), do: {:error, :none}

  @doc """
  The unpacked bundle for this platform: `{:ok, dir}` once it is
  downloaded, checked and unpacked (once per machine), or why it cannot
  be. `opts` take `:progress` (`Argus.FlowLog.Toolchain.announce/2`).
  """
  @spec fetch(keyword()) :: {:ok, Path.t()} | {:error, reason()}
  def fetch(opts \\ []) do
    with {:ok, offer} <- offer() do
      dir = Path.join([Toolchain.root(), "prebuilt", offer.sha256])

      if unpacked?(dir) do
        {:ok, dir}
      else
        Toolchain.locked({:prebuilt, offer.sha256}, fn ->
          if unpacked?(dir), do: {:ok, dir}, else: download(offer, dir, opts)
        end)
      end
    end
  end

  defp unpacked?(dir), do: File.regular?(Path.join(dir, "bundle.json"))

  @doc """
  The unpacked bundles under the cache root other than the one this
  package offers: those of other releases, which nothing here uses again.
  """
  @spec stale() :: [Path.t()]
  def stale do
    keep =
      case offer() do
        {:ok, offer} -> offer.sha256
        {:error, _} -> nil
      end

    dir = Path.join(Toolchain.root(), "prebuilt")

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names), name != keep, name =~ @digest, do: Path.join(dir, name)

      {:error, _} ->
        []
    end
  end

  @doc "The tool in the unpacked bundle at `dir`, when it holds one."
  @spec tool(Path.t()) :: {:ok, Path.t()} | :error
  def tool(dir), do: regular(Path.join([dir, "bin", "argus-flowlog-tool"]))

  @doc """
  The engine and its manifest for `digest` in the unpacked bundle at
  `dir`, when it holds them.
  """
  @spec engine(Path.t(), String.t()) :: {:ok, Path.t(), Path.t()} | :error
  def engine(dir, digest) do
    base = Path.join([dir, "engines", digest])

    with {:ok, engine} <- regular(Path.join(base, "engine")),
         {:ok, manifest} <- regular(Path.join(base, "manifest.json")),
         do: {:ok, engine, manifest}
  end

  defp regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _ -> :error
    end
  end

  # ── Downloading and unpacking ───────────────────────────────────────

  defp download(offer, dir, opts) do
    Toolchain.announce(
      opts,
      "fetching argus's prebuilt FlowLog engines (#{div(offer.bytes, 1_000_000)} MB, once per release)"
    )

    parent = Path.dirname(dir)
    File.mkdir_p!(parent)
    scratch = Path.join(parent, ".fetch-#{:os.getpid()}-#{System.unique_integer([:positive])}")
    file = scratch <> ".tar.gz"

    try do
      with :ok <- get(offer.url, file),
           :ok <- check_sum(file, offer.sha256),
           :ok <- check_entries(file),
           :ok <- unpack(file, scratch),
           :ok <- check_bundle(scratch) do
        case File.rename(scratch, dir) do
          :ok -> {:ok, dir}
          # Another VM unpacked the same bundle first.
          {:error, :eexist} -> {:ok, dir}
          {:error, :enotempty} -> {:ok, dir}
          {:error, reason} -> {:error, {:bad_bundle, "cannot install it: #{inspect(reason)}"}}
        end
      end
    after
      File.rm(file)
      File.rm_rf(scratch)
    end
  end

  defp get("file://" <> path, file) do
    case File.cp(path, file) do
      :ok -> :ok
      {:error, reason} -> {:error, {:download_failed, "file://" <> path, reason}}
    end
  end

  defp get("https://" <> _ = url, file) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      request = {String.to_charlist(url), [{~c"user-agent", ~c"argus"}]}

      http = [
        timeout: 1_800_000,
        connect_timeout: 30_000,
        autoredirect: true,
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 4,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]

      case :httpc.request(:get, request, http, stream: String.to_charlist(file)) do
        {:ok, :saved_to_file} -> :ok
        {:ok, {{_, status, _}, _, _}} -> {:error, {:download_failed, url, {:http, status}}}
        {:error, reason} -> {:error, {:download_failed, url, reason}}
      end
    else
      {:error, reason} -> {:error, {:download_failed, url, reason}}
    end
  end

  defp get(url, _file), do: {:error, {:download_failed, url, :unsupported_scheme}}

  defp check_sum(file, expected) do
    actual =
      file
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, actual}}
  end

  # Every entry is a regular file or a directory where a bundle keeps
  # them, so unpacking writes nothing else, and nowhere else.
  defp check_entries(file) do
    case :erl_tar.table(String.to_charlist(file), [:compressed, :verbose]) do
      {:ok, entries} ->
        Enum.find_value(entries, :ok, fn entry ->
          {name, type} = {to_string(elem(entry, 0)), elem(entry, 1)}
          if allowed?(name, type), do: nil, else: {:error, {:bad_bundle, "unexpected #{name}"}}
        end)

      {:error, reason} ->
        {:error, {:bad_bundle, "not a gzipped tar: #{inspect(reason)}"}}
    end
  end

  defp allowed?(name, :directory),
    do: String.trim_trailing(name, "/") in ["bin", "engines"] or engine_dir?(name)

  defp allowed?("bundle.json", :regular), do: true
  defp allowed?("bin/argus-flowlog-tool", :regular), do: true

  defp allowed?("engines/" <> rest, :regular) do
    case String.split(rest, "/") do
      [digest, file] when file in ["engine", "manifest.json"] -> digest =~ @digest
      _ -> false
    end
  end

  defp allowed?(_name, _type), do: false

  defp engine_dir?("engines/" <> rest), do: String.trim_trailing(rest, "/") =~ @digest
  defp engine_dir?(_), do: false

  defp unpack(file, dir) do
    File.mkdir_p!(dir)

    case :erl_tar.extract(String.to_charlist(file), [:compressed, {:cwd, String.to_charlist(dir)}]) do
      :ok ->
        File.chmod!(dir, 0o700)
        for {:ok, path} <- [tool(dir)], do: File.chmod!(path, 0o755)

        for engine <- Path.wildcard(Path.join([dir, "engines", "*", "engine"])),
            do: File.chmod!(engine, 0o755)

        :ok

      {:error, reason} ->
        {:error, {:bad_bundle, "cannot unpack it: #{inspect(reason)}"}}
    end
  end

  defp check_bundle(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "bundle.json")),
         %{"format" => @format, "native" => native, "triple" => triple} <- :json.decode(text),
         {:ok, ^triple} <- platform() do
      if native == Native.digest(),
        do: :ok,
        else: {:error, {:bad_bundle, "built from other toolchain sources (#{native})"}}
    else
      _ ->
        {:error, {:bad_bundle, "its bundle.json is missing, unreadable or for another platform"}}
    end
  rescue
    _ -> {:error, {:bad_bundle, "its bundle.json is not JSON"}}
  end

  # ── Making bundles (a release's CI) ─────────────────────────────────

  @doc """
  Writes the bundle of `engines` (`{program, digest, executable,
  manifest_json_path}`) and the tool at `tool` to
  `out_dir/argus-flowlog-<triple>.tar.gz`, with its offer beside it
  (`.json`: the asset's name, SHA-256 and size, and the sources and
  platform it was built for), and returns the offer's path.
  """
  @spec write_bundle(Path.t(), [{Path.t(), String.t(), Path.t(), Path.t()}], Path.t()) ::
          {:ok, Path.t()} | {:error, reason()}
  def write_bundle(tool, engines, out_dir) do
    with {:ok, triple} <- platform() do
      File.mkdir_p!(out_dir)
      asset = "argus-flowlog-#{triple}.tar.gz"
      archive = Path.join(out_dir, asset)
      staging = Path.join(out_dir, ".bundle-#{System.unique_integer([:positive])}")
      File.mkdir_p!(staging)

      try do
        bundle = %{
          "format" => @format,
          "native" => Native.digest(),
          "triple" => triple,
          "engines" => Map.new(engines, fn {program, digest, _, _} -> {digest, program} end)
        }

        File.write!(Path.join(staging, "bundle.json"), :json.encode(bundle))

        files =
          [{"bundle.json", Path.join(staging, "bundle.json")}, {"bin/argus-flowlog-tool", tool}] ++
            Enum.flat_map(engines, fn {_program, digest, executable, manifest} ->
              [
                {"engines/#{digest}/engine", executable},
                {"engines/#{digest}/manifest.json", manifest}
              ]
            end)

        entries =
          for {name, path} <- files, do: {String.to_charlist(name), String.to_charlist(path)}

        :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])

        sha =
          archive
          |> File.stream!(1_048_576)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        offer = %{
          "asset" => asset,
          "triple" => triple,
          "native" => Native.digest(),
          "sha256" => sha,
          "bytes" => File.stat!(archive).size
        }

        path = archive <> ".json"
        File.write!(path, :json.encode(offer))
        {:ok, path}
      after
        File.rm_rf(staging)
      end
    end
  end

  @doc """
  The package's offer (`priv/flowlog/prebuilt.json`) for the bundles a
  release's builds wrote (`write_bundle/3`'s `.json` files), each at
  `base_url/<asset>`. Every bundle must be built from these sources.
  """
  @spec offer_json([Path.t()], String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def offer_json(offer_paths, base_url) do
    offers = Enum.map(offer_paths, &(&1 |> File.read!() |> :json.decode()))

    case Enum.reject(offers, &(&1["native"] == Native.digest())) do
      [] ->
        bundles =
          Map.new(offers, fn offer ->
            {offer["triple"],
             %{
               "url" => String.trim_trailing(base_url, "/") <> "/" <> offer["asset"],
               "sha256" => offer["sha256"],
               "bytes" => offer["bytes"]
             }}
          end)

        json = %{"format" => @format, "native" => Native.digest(), "bundles" => bundles}
        {:ok, IO.iodata_to_binary(:json.format(json)) <> "\n"}

      other ->
        {:error,
         "built from other toolchain sources than these: " <>
           Enum.map_join(other, ", ", &(&1["asset"] || "?"))}
    end
  end

  @doc "A sentence for a user saying why no bundle was used."
  @spec describe(reason()) :: String.t()
  def describe(:disabled), do: "prebuilt engines are turned off (ARGUS_FLOWLOG_PREBUILT=0)"
  def describe(:none), do: "this build of argus offers no prebuilt engines"

  def describe({:unsupported_platform, arch}),
    do: "argus publishes no prebuilt engines for #{arch}"

  def describe({:no_bundle, triple}), do: "this release has no prebuilt engines for #{triple}"

  def describe({:other_sources, _}),
    do: "the prebuilt engines this package names were built from other toolchain sources"

  def describe({:download_failed, url, reason}),
    do: "downloading #{url} failed: #{inspect(reason)}"

  def describe({:checksum_mismatch, expected, actual}),
    do:
      "the download's SHA-256 is #{actual}, not the #{expected} the package names; it was not used"

  def describe({:bad_bundle, detail}), do: "the downloaded bundle was refused: #{detail}"
end
