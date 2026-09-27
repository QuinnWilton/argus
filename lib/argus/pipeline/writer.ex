defmodule Argus.Pipeline.Writer do
  @moduledoc """
  Appends one module's facts at a time to per-relation `.facts` files,
  opening each file on first use. Rows land in the order extraction
  yields them, which `Argus.Pipeline` keeps deterministic. `encode/2`
  is also how the query graph keeps a module's rows (`Argus.Graph.Pack`).
  """

  @enforce_keys [:dir, :written, :files]
  defstruct [:dir, :written, :files]

  @typedoc """
  Which relations receive rows: every one (`nil`), the ones named, or
  every one but those named (`{:except, names}`).
  """
  @type written :: MapSet.t(atom()) | {:except, MapSet.t(atom())} | nil

  @type t :: %__MODULE__{
          dir: Path.t(),
          written: written(),
          files: %{atom() => File.io_device()}
        }

  @spec new(Path.t(), written()) :: t()
  def new(dir, written), do: %__MODULE__{dir: dir, written: written, files: %{}}

  @doc """
  The filter a `relations:` option names (`Argus.Pipeline.run/3`):
  `:all`, a list of relations, or `{:except, relations}`.
  """
  @spec written(:all | [atom()] | {:except, [atom()]}) :: written()
  def written(:all), do: nil
  def written({:except, names}) when is_list(names), do: {:except, MapSet.new(names)}
  def written(names) when is_list(names), do: MapSet.new(names)

  @spec append(t(), Argus.Pipeline.Emit.facts()) :: {:ok, t()} | {:error, term()}
  def append(writer, module_facts) do
    Enum.reduce_while(module_facts, {:ok, writer}, fn {relation, rows}, {:ok, writer} ->
      if rows == [] or skip?(writer, relation) do
        {:cont, {:ok, writer}}
      else
        bytes = Argus.Tsv.encode(Enum.reverse(rows))

        case write_bytes(writer, relation, bytes) do
          {:ok, writer} -> {:cont, {:ok, writer}}
          error -> {:halt, error}
        end
      end
    end)
  end

  @doc """
  A module's facts as `append_encoded/2` writes them: per relation, the
  bytes of its lines, in the order `append/2` would write the rows, for
  the relations `written` lets through (`t:written/0`) that have rows.
  What a worker does so that the caller only writes.
  """
  @spec encode(Argus.Pipeline.Emit.facts(), written()) :: %{atom() => binary()}
  def encode(module_facts, written) do
    for {relation, rows} <- module_facts,
        rows != [],
        written?(written, relation),
        into: %{},
        do: {relation, IO.iodata_to_binary(Argus.Tsv.encode(Enum.reverse(rows)))}
  end

  @doc "Appends facts `encode/2` encoded."
  @spec append_encoded(t(), %{atom() => binary()}) :: {:ok, t()} | {:error, term()}
  def append_encoded(writer, encoded) do
    Enum.reduce_while(encoded, {:ok, writer}, fn {relation, bytes}, {:ok, writer} ->
      case write_bytes(writer, relation, bytes) do
        {:ok, writer} -> {:cont, {:ok, writer}}
        error -> {:halt, error}
      end
    end)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{files: files}) do
    Enum.each(files, fn {_relation, device} -> File.close(device) end)
  end

  defp skip?(%__MODULE__{written: written}, relation), do: not written?(written, relation)

  defp written?(nil, _relation), do: true
  defp written?({:except, except}, relation), do: not MapSet.member?(except, relation)
  defp written?(%MapSet{} = only, relation), do: MapSet.member?(only, relation)

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

  defp write_bytes(writer, relation, bytes) do
    with {:ok, device, writer} <- device(writer, relation) do
      case :file.write(device, bytes) do
        :ok ->
          {:ok, writer}

        {:error, reason} ->
          {:error, {:write_failed, Path.join(writer.dir, "#{relation}.facts"), reason}}
      end
    end
  end
end
