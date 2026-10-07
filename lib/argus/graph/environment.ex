defmodule Argus.Graph.Environment do
  @moduledoc """
  The values of the graph's environment inputs (`Argus.Graph.Inputs`),
  as a frontend computes them before a run: never inside a query.

    * `solver/2` — the engine settings: the FlowLog toolchain's version
      (its sources' digest), the timeout a solve has and the workers an
      engine runs.
    * `code_index/2` — each directory the specs are read from (the
      specs source's, or the code path's) outside OTP and Elixir (and
      the build's consolidated protocols), named by itself.
    * `app_code/1` — a directory's beams by their stamps: it moves when
      one is rebuilt, and whoever read a module's specs from there looks
      at them again (`Argus.Graph.Reads`'s `installed_specs`), which is
      cheap and comes out equal unless the specs changed.
    * `stamps/1` — every directory's `app_code` of an index, read side
      by side: a caller opening many sessions in one VM over the same
      code (the corpus) reads them once and hands them to each.
  """

  alias Roux.Blob

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc """
  The engine settings: `%{version:, timeout:, workers:}`. The version is
  the FlowLog toolchain's (`Argus.FlowLog.Native.digest/0`), which every
  program's digest carries; whether Rust is installed is no part of it,
  and is asked only by a solve that misses the store
  (`Argus.FlowLog.Toolchain`).

  `:timeout` in `opts` sets the timeout (default
  `Argus.FlowLog.default_timeout/0`), and `:workers` the dataflow
  workers (default `Argus.FlowLog.default_workers/0`). The old
  `:souffle_bin` and `:souffle_timeout` options raise.
  """
  @spec solver(Blob.t() | nil, keyword()) ::
          %{version: String.t(), timeout: timeout(), workers: pos_integer()}
  def solver(_store, opts \\ []) do
    for old <- [:souffle_bin, :souffle_timeout], Keyword.has_key?(opts, old) do
      raise ArgumentError,
            "#{inspect(old)}: argus solves on FlowLog engines since 0.22; " <>
              "use :timeout for a solve's timeout"
    end

    %{
      version: Argus.FlowLog.Native.digest(),
      timeout: Keyword.get(opts, :timeout, Argus.FlowLog.default_timeout()),
      workers: Keyword.get(opts, :workers, Argus.FlowLog.default_workers())
    }
  end

  @doc """
  Each directory the specs are read from and not the runtime's — the
  source's (`Argus.Specs.Source`), or the code path's without one:
  `%{dir => name}`, a directory named by itself.

  `own` are the directories whose every beam is an input of the graph
  (a project's own ebins, as a driver syncs them): a read of a module
  there depends on its beam's input, and stamping them is wasted.
  """
  @spec code_index(Argus.Specs.Source.t() | nil, [Path.t()]) ::
          %{optional(String.t()) => String.t()}
  def code_index(source \\ nil, own \\ []) do
    otp = List.to_string(:code.root_dir()) <> "/"
    elixir = (:elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()) <> "/"
    own = MapSet.new(own, &Path.expand/1)

    dirs =
      case source do
        nil -> Enum.map(:code.get_path(), &List.to_string/1)
        %Argus.Specs.Source{index: index} -> index |> Map.values() |> Enum.map(&Path.dirname/1)
      end

    for dir <- Enum.uniq(dirs),
        dir = Path.expand(dir),
        not MapSet.member?(own, dir),
        not String.starts_with?(dir, otp),
        not String.starts_with?(dir, elixir),
        "consolidated" not in Path.split(dir),
        File.dir?(dir),
        into: %{},
        do: {dir, dir}
  end

  @doc """
  The `app_code/1` of every directory of `index` (`code_index/2`), by
  its name, read side by side: stamping is file-status calls, and the
  directories are independent.
  """
  @spec stamps(%{optional(String.t()) => String.t()}) :: %{optional(String.t()) => String.t()}
  def stamps(index) do
    index
    |> Task.async_stream(fn {dir, name} -> {name, app_code(dir)} end,
      max_concurrency: 2 * System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, stamp} -> stamp end)
  end

  @doc """
  A digest of the stamps (name, size, modification time, inode) of every
  beam in `dir`.
  """
  @spec app_code(Path.t()) :: String.t()
  def app_code(dir) do
    # Raw: the calls never queue behind the file server, whose one
    # process every `File` call of the VM goes through.
    names =
      case :prim_file.list_dir(dir) do
        {:ok, names} -> names |> Enum.map(&List.to_string/1) |> Enum.sort()
        {:error, _} -> []
      end

    stamps =
      for name <- names, String.ends_with?(name, ".beam") do
        case :file.read_file_info(Path.join(dir, name), [:raw, {:time, :posix}]) do
          {:ok, file_info(size: size, mtime: mtime, inode: inode)} -> {name, size, mtime, inode}
          {:error, reason} -> {name, reason}
        end
      end

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(stamps, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
