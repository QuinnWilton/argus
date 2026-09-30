defmodule Argus.Graph.FunctionPack do
  @moduledoc "The function extraction graph behind the existing relation and solve interface."

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.Pack
  alias Roux.Runtime, as: R

  defquery :module_facts,
    key: module,
    store: :blob,
    timeout: &__MODULE__.timeout/0,
    on_timeout: &__MODULE__.timed_out/2,
    transient: &match?({:ok, %{lost: true}}, &1) do
    with {:ok, pack, held} <- rebuild(db, module, :extracted) do
      R.hold(held)
      {:ok, pack}
    end
  end

  defquery :module_in_process,
    key: module,
    store: :blob,
    timeout: &__MODULE__.timeout/0,
    on_timeout: &__MODULE__.timed_out/2,
    transient: &match?({:ok, %{lost: true}}, &1) do
    with {:ok, pack, held} <- rebuild(db, module, :in_process) do
      R.hold(held)
      {:ok, pack}
    end
  end

  @doc false
  @spec timeout() :: timeout()
  def timeout, do: Application.get_env(:argus_beam, :extraction_timeout, 120_000)

  @doc false
  @spec timed_out(Roux.Database.t(), term()) :: {:ok, Pack.t()}
  def timed_out(db, module) do
    R.query(db, :module_beam, module)
    name = R.query(db, :module_name, module)
    reason = "extraction did not finish within #{timeout()} ms"
    rows = %{extraction_error: [[inspect(name), "pipeline", reason]]}
    encoded = Argus.Pipeline.Writer.encode(rows, MapSet.new([:extraction_error]))
    {pack, held} = Pack.from_segments(db.blob, name, [{:base, encoded}])
    R.hold(held)
    {:ok, %{pack | lost: true}}
  end

  defquery :base_code, key: :all do
    R.query(db, :extraction_code, :base)
  end

  defquery :module_semantic, key: module do
    with {:ok, %{relations: relations}} <- R.query(db, :module_facts, module) do
      {:ok, Map.delete(relations, :line_info)}
    end
  end

  defquery :extraction_segments, key: {module, kind}, store: :blob do
    segments(db, module, kind)
  end

  @doc false
  @spec rebuild(Roux.Database.t(), term(), Pack.kind()) ::
          {:ok, Pack.t(), [Roux.Blob.digest()]} | {:error, term()}
  def rebuild(db, module, kind) do
    with {:ok, segments} <- R.query(db, :extraction_segments, {module, kind}) do
      name = R.query(db, :module_name, module)
      {pack, held} = Pack.from_segments(db.blob, name, segments)
      {:ok, pack, held}
    end
  end

  defp segments(db, module, kind) do
    with {:ok, base} <- R.query(db, :extraction_base_rows, module) do
      in_process = Argus.Schema.in_process_only()

      segments =
        case kind do
          :in_process ->
            [{:base, Map.take(base, in_process)}]

          :extracted ->
            {:ok, locations} = R.query(db, :extraction_locations, module)
            base = base |> Map.drop(in_process) |> Map.merge(locations)

            producers =
              for producer <- R.query(db, :extraction_producers, :all) do
                {:ok, rows} = R.query(db, :extraction_producer, {module, producer})
                {producer, Map.drop(rows, in_process)}
              end

            [{:base, base} | producers]
        end

      {:ok, segments}
    end
  end
end
