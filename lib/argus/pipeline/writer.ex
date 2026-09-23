defmodule Argus.Pipeline.Writer do
  @moduledoc """
  Appends one module's facts at a time to per-relation `.facts` files,
  opening each file on first use. Rows land in the order extraction
  yields them, which `Argus.Pipeline` keeps deterministic.
  """

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

  @doc """
  A module's facts as `append_encoded/2` writes them: per relation, the
  bytes of its lines, in the order `append/2` would write the rows, for
  the relations `written` names (every one when `nil`) that have rows.
  What a worker does so that the caller only writes.
  """
  @spec encode(Argus.Pipeline.Emit.facts(), MapSet.t(atom()) | nil) :: %{atom() => binary()}
  def encode(module_facts, written) do
    for {relation, rows} <- module_facts,
        rows != [],
        written == nil or MapSet.member?(written, relation),
        into: %{},
        do: {relation, IO.iodata_to_binary(Argus.Tsv.encode(Enum.reverse(rows)))}
  end

  @doc "Appends facts `encode/2` encoded."
  @spec append_encoded(t(), %{atom() => binary()}) :: {:ok, t()} | {:error, term()}
  def append_encoded(writer, encoded) do
    Enum.reduce_while(encoded, {:ok, writer}, fn {relation, bytes}, {:ok, writer} ->
      with {:ok, device, writer} <- device(writer, relation),
           :ok <- write_bytes(device, writer.dir, relation, bytes) do
        {:cont, {:ok, writer}}
      else
        error -> {:halt, error}
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

  defp write(device, dir, relation, rows),
    do: write_bytes(device, dir, relation, Argus.Tsv.encode(rows))

  defp write_bytes(device, dir, relation, bytes) do
    case :file.write(device, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, Path.join(dir, "#{relation}.facts"), reason}}
    end
  end
end
