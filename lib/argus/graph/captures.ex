defmodule Argus.Graph.Captures do
  @moduledoc """
  What a closure's parameters hold, decided where the closure is built:
  captured parameter provenance and counted closures, as explicit
  extraction dependencies of the producers that extract one function at
  a time.
  """

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

  # The module's counted closures (`Argus.Extractors.ParamFlow.Counters`):
  # whether a closure's first parameter is a pair of an element and its
  # counter is decided where the closure is built, in another function.
  defquery :extraction_counted_closures, key: module, store: :blob do
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
          |> Argus.Extractors.ParamFlow.Counters.closures()
      end
    end
  end

  defquery :extraction_counted_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)
    db |> R.query(:extraction_counted_closures, module) |> Map.take([function])
  end

  defquery :extraction_capture_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)
    db |> R.query(:extraction_capture_origins, module) |> Map.take([function])
  end
end
