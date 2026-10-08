defmodule Argus.RawFile do
  @moduledoc """
  File reads that skip the VM's file server.

  `File.read/1`, `File.stat/2`, `File.ls/1` and `Path.wildcard/2` each
  send a request to one process, `:file_server_2`, which serves the VM's
  requests one at a time. A run of argus stats its rules, programs and
  facts on every solve, side by side, and they queue there: under a
  test suite's load it held a queue three quarters of the time. These
  read the file system directly, as `:file`'s `:raw` option does, for the
  local files argus reads.
  """

  @doc "`File.stat/2` with POSIX times, read directly."
  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path) do
    case :file.read_file_info(path, [:raw, time: :posix]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`File.read/1`, read directly."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: :file.read_file(path, [:raw])

  @doc "`File.read!/1`, read directly."
  @spec read!(Path.t()) :: binary()
  def read!(path) do
    case read(path) do
      {:ok, content} -> content
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc "`File.ls/1`, listed directly."
  @spec ls(Path.t()) :: {:ok, [String.t()]} | {:error, File.posix()}
  def ls(dir) do
    case :prim_file.list_dir(dir) do
      {:ok, names} -> {:ok, Enum.map(names, &List.to_string/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`File.mkdir_p/1`, made directly."
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path) do
    case :prim_file.make_dir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if match?({:ok, %File.Stat{type: :directory}}, stat(path)),
          do: :ok,
          else: {:error, :eexist}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with true <- parent != path || {:error, :enoent},
             :ok <- mkdir_p(parent) do
          case :prim_file.make_dir(path) do
            {:error, :eexist} -> mkdir_p(path)
            made -> made
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "`File.mkdir_p!/1`, made directly."
  @spec mkdir_p!(Path.t()) :: :ok
  def mkdir_p!(path) do
    case mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory (with -p)", path: path
    end
  end

  @doc """
  Every regular file under `root` whose name ends in `extension`, as
  `Path.wildcard(Path.join(root, "**/*" <> extension))` gives them:
  sorted, and leaving out a name that starts with a dot. A directory
  that cannot be listed holds none.
  """
  @spec files(Path.t(), String.t()) :: [Path.t()]
  def files(root, extension), do: root |> walk(extension, []) |> Enum.sort()

  defp walk(dir, extension, acc) do
    case ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn
          "." <> _, acc ->
            acc

          name, acc ->
            path = Path.join(dir, name)

            case stat(path) do
              {:ok, %File.Stat{type: :directory}} ->
                walk(path, extension, acc)

              {:ok, %File.Stat{type: :regular}} ->
                if String.ends_with?(name, extension), do: [path | acc], else: acc

              _ ->
                acc
            end
        end)

      {:error, _} ->
        acc
    end
  end
end
