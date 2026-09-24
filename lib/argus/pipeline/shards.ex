defmodule Argus.Pipeline.Shards do
  @moduledoc """
  A facts directory put together from producers' directories
  (`Argus.Pipeline.run_shards/3`): each relation's file is the files of
  that name in the producers' directories, joined in producer order.

  Almost every relation has one producer, and its file is moved or
  linked into place as it is; the few written by several
  (`extraction_error`, `imprecision`, `dynamic_call`) are the parts
  concatenated. A file is never written through: a part is moved or
  linked to its target, and a joined file is written under a scratch name
  and renamed over it, so a directory linked from a store never reaches
  back into the store's files.
  """

  @typedoc """
  Each relation's file name (`call_arg.facts`) and the files holding its
  rows, in producer order.
  """
  @type parts :: %{String.t() => [Path.t()]}

  @doc """
  The parts of each relation across `dirs`, the producers' directories
  in producer order. A directory that does not exist has none.
  """
  @spec parts([Path.t()]) :: parts()
  def parts(dirs) do
    dirs
    |> Enum.flat_map(fn dir ->
      for name <- ls(dir), String.ends_with?(name, ".facts"), do: {name, Path.join(dir, name)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Writes each relation of `parts` into `target` (which must exist),
  replacing a file already there: `:move` renames a lone part into
  place (the part's directory is the caller's scratch space), `:link`
  hard-links it (copying where the two are on different volumes). A
  relation with several parts is always their concatenation.
  """
  @spec assemble(parts(), Path.t(), :move | :link) :: :ok | {:error, term()}
  def assemble(parts, target, mode) when mode in [:move, :link] do
    Enum.reduce_while(parts, :ok, fn {name, files}, :ok ->
      case place(files, Path.join(target, name), mode) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Puts the rows of `files`, in order, at `target`, replacing what is
  there: see `assemble/3`.
  """
  @spec place([Path.t()], Path.t(), :move | :link) :: :ok | {:error, term()}
  def place([], target, _mode), do: write_new(target, fn _device -> :ok end)

  def place([file], target, :move) do
    case File.rename(file, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:place_failed, target, reason}}
    end
  end

  def place([file], target, :link) do
    scratch = scratch_name(target)

    result =
      with {:error, _} <- File.ln(file, scratch),
           {:error, reason} <- File.cp(file, scratch) do
        {:error, {:place_failed, target, reason}}
      end

    with :ok <- result, :ok <- rename(scratch, target), do: :ok
  end

  def place(files, target, _mode) do
    write_new(target, fn device ->
      Enum.reduce_while(files, :ok, fn file, :ok ->
        case :file.copy(file, device) do
          {:ok, _bytes} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:place_failed, target, reason}}}
        end
      end)
    end)
  end

  # A file written whole under a scratch name beside `target`, then
  # renamed over it.
  defp write_new(target, fill) do
    scratch = scratch_name(target)

    result =
      case File.open(scratch, [:write, :raw, :binary]) do
        {:ok, device} ->
          try do
            fill.(device)
          after
            File.close(device)
          end

        {:error, reason} ->
          {:error, {:place_failed, target, reason}}
      end

    case result do
      :ok ->
        rename(scratch, target)

      {:error, _} = error ->
        File.rm(scratch)
        error
    end
  end

  defp rename(scratch, target) do
    case File.rename(scratch, target) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(scratch)
        {:error, {:place_failed, target, reason}}
    end
  end

  defp scratch_name(target),
    do: "#{target}.#{:os.getpid()}-#{System.unique_integer([:positive])}.part"

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end
end
