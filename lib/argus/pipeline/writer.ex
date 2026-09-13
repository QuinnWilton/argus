defmodule Argus.Pipeline.Writer do
  @moduledoc """
  Appends one module's facts at a time to per-relation `.facts` files,
  opening each file on first use. Rows land in the order extraction
  yields them, which `Argus.Pipeline` keeps deterministic.
  """

  alias Argus.Pipeline

  @enforce_keys [:dir, :written, :files]
  defstruct [:dir, :written, :files]

  @type t :: %__MODULE__{
          dir: Path.t(),
          written: MapSet.t(atom()) | nil,
          files: %{atom() => File.io_device()}
        }

  @spec new(Path.t(), MapSet.t(atom()) | nil) :: t()
  def new(dir, written), do: %__MODULE__{dir: dir, written: written, files: %{}}

  @spec append(t(), Argus.Pipeline.Emit.facts()) :: {:ok, t()} | {:error, term()}
  def append(writer, module_facts) do
    Enum.reduce_while(module_facts, {:ok, writer}, fn {relation, rows}, {:ok, writer} ->
      if rows == [] or skip?(writer, relation) do
        {:cont, {:ok, writer}}
      else
        with {:ok, device, writer} <- device(writer, relation),
             :ok <- write(device, writer.dir, relation, Enum.reverse(rows)) do
          {:cont, {:ok, writer}}
        else
          error -> {:halt, error}
        end
      end
    end)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{files: files}) do
    Enum.each(files, fn {_relation, device} -> File.close(device) end)
  end

  defp skip?(%__MODULE__{written: nil}, _relation), do: false
  defp skip?(%__MODULE__{written: written}, relation), do: not MapSet.member?(written, relation)

  defp device(%__MODULE__{files: files} = writer, relation) do
    case Map.fetch(files, relation) do
      {:ok, device} ->
        {:ok, device, writer}

      :error ->
        path = Path.join(writer.dir, "#{relation}.facts")

        case File.open(path, [:append, :raw, :binary, {:delayed_write, 1_048_576, 2_000}]) do
          {:ok, device} -> {:ok, device, %{writer | files: Map.put(files, relation, device)}}
          {:error, reason} -> {:error, {:write_failed, path, reason}}
        end
    end
  end

  defp write(device, dir, relation, rows) do
    case :file.write(device, Pipeline.rows_iodata(rows)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, Path.join(dir, "#{relation}.facts"), reason}}
    end
  end
end
