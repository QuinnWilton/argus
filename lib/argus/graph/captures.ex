defmodule Argus.Graph.Captures do
  @moduledoc """
  What a function-local producer reads of the rest of its module, as an
  explicit extraction dependency: captured parameter provenance
  (`Argus.Extractors.ApiCalls`), counted closures
  (`Argus.Extractors.Dependence`), and where a function's returned values
  go in its callers (`Argus.Extractors.ProcessRegistry`). Each is
  computed over the module's canonical bodies and taken for one function,
  so an edit elsewhere in the module re-extracts the function only when
  what it reads changed.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Roux.Runtime, as: R

  defquery :extraction_capture_origins, key: module, store: :blob do
    with {:ok, data} <- module_data(db, module) do
      if data == nil, do: %{}, else: Argus.Extractors.ApiCalls.capture_origins(data)
    end
  end

  defquery :extraction_capture_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)
    db |> R.query(:extraction_capture_origins, module) |> Map.take([function])
  end

  # The module's counted closures (`Argus.Extractors.ParamFlow.Counters`):
  # whether a closure's first parameter is a pair of an element and its
  # counter is decided where the closure is built, in another function.
  defquery :extraction_counted_closures, key: module, store: :blob do
    with {:ok, data} <- module_data(db, module) do
      if data == nil, do: %{}, else: Argus.Extractors.ParamFlow.Counters.closures(data)
    end
  end

  defquery :extraction_counted_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)
    db |> R.query(:extraction_counted_closures, module) |> Map.take([function])
  end

  defquery :extraction_returns_context, key: {module, {name, arity}} do
    function = Argus.InstrId.func_id(R.query(db, :module_name, module), name, arity)

    with {:ok, data} <- module_data(db, module) do
      if data == nil,
        do: %{},
        else: Argus.Extractors.ProcessRegistry.returns_to(data, [function])
    end
  end

  # The module's canonical function bodies, and its exports, as one
  # module's data: `{:ok, nil}` for a module with no functions.
  defp module_data(db, module) do
    with {:ok, keys} <- R.query(db, :extraction_functions, module) do
      data =
        Enum.map(keys, fn key ->
          {:ok, data} = R.query(db, :extraction_function, {module, key})
          data
        end)

      case data do
        [] ->
          {:ok, nil}

        [first | _] ->
          {:ok,
           first
           |> Map.put(:functions, Enum.flat_map(data, & &1.functions))
           |> Map.put(:exports, Enum.flat_map(data, & &1.exports))}
      end
    end
  end
end
