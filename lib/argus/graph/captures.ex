defmodule Argus.Graph.Captures do
  @moduledoc "Captured parameter provenance as an explicit extraction dependency."

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Roux.Runtime, as: R

  defquery :extraction_capture_origins, key: module, store: :blob do
    with {:ok, keys} <- R.query(db, :extraction_functions, module) do
      data =
        Enum.map(keys, fn key ->
          {:ok, data} = R.query(db, :extraction_function, {module, key})
          data
        end)

      case data do
        [] ->
          %{}

        [first | _] ->
          first
          |> Map.put(:functions, Enum.flat_map(data, & &1.functions))
          |> Argus.Extractors.ApiCalls.capture_origins()
      end
    end
  end

  defquery :extraction_capture_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)
    db |> R.query(:extraction_capture_origins, module) |> Map.take([function])
  end
end
