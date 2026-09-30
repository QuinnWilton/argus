defmodule Argus.Graph.Functions do
  @moduledoc """
  Function and producer queries for incremental extraction.

  Function-local producers read one canonical body and its shared base.
  Producers with module-wide dependencies currently read an assembled base;
  its expensive CFG and reaching-definition work still comes from function queries.
  Content-addressed traces preserve reuse without a session manifest.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.{ExtractionCache, Frontend}
  alias Argus.Instr.Reaching
  alias Argus.Pipeline
  alias Argus.Pipeline.{Base, Disassemble, Function}
  alias Roux.Blob
  alias Roux.Runtime, as: R

  @prepared {__MODULE__, :prepared}

  @local [
    Argus.Extractors.ApiCalls,
    Argus.Extractors.CallArgs,
    Argus.Extractors.CallbackTag,
    Argus.Extractors.Dependence,
    Argus.Extractors.Endpoint,
    Argus.Extractors.Handles,
    Argus.Extractors.LiveView,
    Argus.Extractors.OTP,
    Argus.Extractors.ParamFlow,
    Argus.Extractors.PidFlow,
    Argus.Extractors.ProcessRegistry,
    Argus.Extractors.Purity,
    Argus.Extractors.Reply,
    Argus.Extractors.Router,
    Argus.Extractors.ShutdownReason,
    Argus.Extractors.Sockets,
    Argus.Extractors.Tls
  ]

  @doc "The producers whose facts depend only on one function's prepared body."
  @spec local_producers() :: [module()]
  def local_producers, do: @local

  defquery :extraction_disassembly, key: module, store: :blob do
    case R.query(db, :module_beam, module) do
      {:ok, beam} ->
        with {:ok, data} <- Disassemble.disassemble_path(Frontend.read(beam)) do
          {:ok, Map.delete(data, :beam)}
        end

      :external ->
        {:error, {:external, module}}
    end
  end

  defquery :extraction_functions, key: module do
    with {:ok, data} <- R.query(db, :extraction_disassembly, module) do
      {:ok, for({:function, name, arity, _, _} <- data.functions, do: {name, arity})}
    end
  end

  defquery :extraction_index, key: module, store: :blob do
    with {:ok, data} <- R.query(db, :extraction_disassembly, module) do
      {:ok,
       %{
         module: data.module,
         functions: Map.new(data.functions, &{function_key(&1), &1}),
         entries: Function.entries(data),
         exports: MapSet.new(data.exports, &export_key/1),
         line_table: data.line_table
       }}
    end
  end

  defquery :extraction_function, key: {module, key} do
    with {:ok, data} <- R.query(db, :extraction_index, module) do
      case Map.get(data.functions, key) do
        nil ->
          {:ok, nil}

        function ->
          {function, lines} =
            Function.canonical(function, data.line_table, data.entries)

          {:function, name, arity, entry, _} = function
          exported? = MapSet.member?(data.exports, key)

          {:ok,
           %{
             module: data.module,
             functions: [function],
             exports: if(exported?, do: [{name, arity, entry}], else: []),
             attributes: [],
             imports: [],
             line_table: lines
           }}
      end
    end
  end

  defquery :extraction_code, key: producer do
    db |> R.query(:producer_code, :all) |> Map.fetch!(producer)
  end

  defquery :extraction_producers, key: :all do
    db
    |> R.query(:producer_code, :all)
    |> Map.keys()
    |> Enum.reject(&(&1 == :base))
    |> Enum.sort()
  end

  defquery :extraction_base, key: key, store: :blob do
    with {:ok, data} when data != nil <- R.query(db, :extraction_function, key) do
      code = R.query(db, :extraction_code, :base)

      ExtractionCache.fetch(db, elem(key, 0), :base, {code, data}, fn ->
        Pipeline.extract_data(data, producers: [:base], keep_base: true, trace_imprecision: true)
      end)
    end
  end

  defquery :extraction_base_rows, key: module, store: :blob do
    with {:ok, keys} <- R.query(db, :extraction_functions, module) do
      parts =
        for key <- keys do
          {:ok, base} = R.query(db, :extraction_base, {module, key})
          Map.delete(base.facts.base, :line_info)
        end

      {:ok, merge_rows(parts)}
    end
  end

  defquery :extraction_locations, key: module, store: :blob do
    with {:ok, data} <- R.query(db, :extraction_disassembly, module) do
      rows = Argus.Pipeline.Emit.locations(data.module, data.functions, data.line_table)
      {:ok, Argus.Pipeline.Writer.encode(rows, MapSet.new([:line_info]))}
    end
  end

  defquery :extraction_local, key: {key, producer} do
    with {:ok, base} when base != nil <- R.query(db, :extraction_base, key) do
      code = R.query(db, :extraction_code, producer)
      context = context(db, key, producer)
      input = base_input(db, key, base)

      ExtractionCache.fetch(db, elem(key, 0), producer, {code, input, context}, fn ->
        case input do
          {:unprepared, data} ->
            Pipeline.extract_data(Map.merge(data, context), options(db, producer))

          kept ->
            {module, function} = key

            data =
              prepared_input(db, module, function, kept, fn ->
                data = kept |> Base.restore("") |> prepared()
                {data, export_reaching(data)}
              end)

            Pipeline.extract_prepared(Map.merge(data, context), options(db, producer))
        end
      end)
      |> producer_rows(producer)
    else
      {:ok, nil} -> {:ok, %{}}
      error -> error
    end
  end

  defquery :extraction_metadata, key: module do
    with {:ok, data} <- R.query(db, :extraction_disassembly, module) do
      {:ok,
       %{
         module: data.module,
         attributes: Keyword.delete(data.attributes, :vsn),
         exports:
           Enum.map(data.exports, fn entry ->
             {name, arity} = export_key(entry)
             {name, arity, 0}
           end),
         imports: data.imports
       }}
    end
  end

  defquery :extraction_module_base, key: module do
    with {:ok, keys} <- R.query(db, :extraction_functions, module),
         {:ok, metadata} <- R.query(db, :extraction_metadata, module) do
      parts =
        for key <- keys do
          {:ok, base} = R.query(db, :extraction_base, {module, key})
          base_input(db, {module, key}, base)
        end

      code = Roux.Database.code_version(db, :extraction_module_base)
      identity = Blob.term_digest({code, metadata, parts})

      {:ok,
       %{
         metadata: metadata,
         keys: keys,
         digest: identity,
         prepared?: Enum.all?(parts, &is_binary/1)
       }}
    end
  end

  defquery :extraction_module_producer, key: {module, producer}, store: :blob do
    with {:ok, base} <- R.query(db, :extraction_module_base, module) do
      code = R.query(db, :extraction_code, producer)
      metadata = with_chunks(db, module, producer, base.metadata)

      identity =
        case Map.fetch(metadata, :beam) do
          {:ok, beam} -> {base.digest, Blob.digest(beam)}
          :error -> base.digest
        end

      ExtractionCache.fetch(db, module, producer, {code, identity}, fn ->
        if base.prepared? do
          data =
            prepared_input(db, module, :module, identity, fn ->
              bases =
                for key <- base.keys do
                  {:ok, part} = R.query(db, :extraction_base, {module, key})
                  Base.restore(part.base, "")
                end

              data = assemble(metadata, bases)
              {data, export_reaching(data)}
            end)

          Pipeline.extract_prepared(data, options(db, producer))
        else
          {:ok, data} = R.query(db, :extraction_disassembly, module)
          Pipeline.extract_data(with_chunks(db, module, producer, data), options(db, producer))
        end
      end)
      |> producer_rows(producer)
    end
  end

  defquery :extraction_producer, key: {module, producer}, store: :blob do
    cond do
      producer in [Argus.Extractors.Generated, Argus.Extractors.Specs, Argus.Extractors.Tooling] ->
        R.query(db, :extraction_metadata_rows, {module, producer})

      producer in @local ->
        with {:ok, keys} <- R.query(db, :extraction_functions, module) do
          parts =
            for key <- keys do
              {:ok, rows} = R.query(db, :extraction_local, {{module, key}, producer})
              rows
            end

          extra =
            if producer in [Argus.Extractors.OTP, Argus.Extractors.Purity] do
              {:ok, rows} = R.query(db, :extraction_attribute_rows, {module, producer})
              [rows]
            else
              []
            end

          {:ok, merge_rows(extra ++ parts)}
        end

      true ->
        R.query(db, :extraction_module_producer, {module, producer})
    end
  end

  defquery :extraction_attributes, key: {module, names} do
    with {:ok, metadata} <- R.query(db, :extraction_metadata, module) do
      {:ok, Keyword.take(metadata.attributes, names)}
    end
  end

  defquery :extraction_attribute_rows, key: {module, producer}, store: :blob do
    names = if producer == Argus.Extractors.OTP, do: [:behaviour, :behavior], else: [:argus_pure]
    {:ok, attributes} = R.query(db, :extraction_attributes, {module, names})
    code = R.query(db, :extraction_code, producer)
    data = empty_data(R.query(db, :module_name, module)) |> Map.put(:attributes, attributes)

    ExtractionCache.fetch(db, module, producer, {code, data}, fn ->
      Pipeline.extract_prepared(data, options(db, producer))
    end)
    |> producer_rows(producer)
  end

  # These producers read metadata or calls, never CFGs or reaching definitions.
  defquery :extraction_metadata_rows, key: {module, producer}, store: :blob do
    with {:ok, disassembly} <- R.query(db, :extraction_disassembly, module) do
      data = Map.merge(empty_data(disassembly.module), disassembly)
      data = with_chunks(db, module, producer, data)
      code = R.query(db, :extraction_code, producer)

      ExtractionCache.fetch(db, module, producer, {code, data}, fn ->
        Pipeline.extract_prepared(data, options(db, producer))
      end)
      |> producer_rows(producer)
    end
  end

  defp empty_data(module) do
    %{
      module: module,
      attributes: [],
      functions: [],
      exports: [],
      imports: [],
      line_table: %{},
      typed: %{},
      cfg: %{},
      reaching: MapSet.new()
    }
  end

  defp function_key({:function, name, arity, _, _}), do: {name, arity}

  # Keeping a base is optional in the pipeline. If serialization failed,
  # retain the body as its identity and recompute through the guarded passes.
  defp base_input(db, key, %{base: nil}) do
    {:ok, data} = R.query(db, :extraction_function, key)
    {:unprepared, data}
  end

  defp base_input(_db, _key, %{base: kept}), do: kept

  defp export_reaching(%{reaching: nil}), do: nil
  defp export_reaching(data), do: Reaching.export(data.functions)

  defp context(db, key, Argus.Extractors.ApiCalls),
    do: %{capture_origins: R.query(db, :extraction_capture_context, key)}

  defp context(_, _, _), do: %{}

  defp export_key({name, arity, _}), do: {name, arity}
  defp export_key({:atom, name, arity, _}), do: {name, arity}

  # The worker reuses these indexes across producers. Keep only its current
  # module, and restore reaching solutions even on a hit: another query may
  # have installed a different module's process-local reaching cache.
  defp prepared_input(db, module, key, identity, prepare) do
    scope = {Roux.Database.id(db), module, Roux.Database.code_version(db, :extraction_local)}

    entries =
      case Process.get(@prepared) do
        {^scope, entries} -> entries
        _ -> %{}
      end

    {data, solutions} =
      case Map.get(entries, key) do
        {^identity, data, solutions} ->
          {data, solutions}

        _ ->
          {data, solutions} = prepare.()
          data = Pipeline.prepare_indexes(data)
          Process.put(@prepared, {scope, Map.put(entries, key, {identity, data, solutions})})
          {data, solutions}
      end

    if solutions, do: Reaching.restore(data.functions, solutions)
    data
  end

  defp prepared(restored) do
    {:ok, typed} = restored.typed
    Map.merge(restored.data, %{typed: typed, cfg: restored.cfg, reaching: restored.reaching})
  end

  defp assemble(metadata, bases) do
    parts = Enum.map(bases, &prepared/1)

    typed =
      parts
      |> Enum.reduce(%{}, fn part, rows ->
        Enum.reduce(part.typed || %{}, rows, fn {relation, own}, rows ->
          Map.update(rows, relation, [own], &[own | &1])
        end)
      end)
      |> Map.new(fn {relation, chunks} ->
        {relation, chunks |> Enum.reverse() |> Enum.concat()}
      end)

    Map.merge(metadata, %{
      functions: Enum.flat_map(parts, & &1.functions),
      line_table: Enum.reduce(parts, %{}, &Map.merge(&2, &1.line_table)),
      cfg: Enum.reduce(parts, %{}, &Map.merge(&2, &1.cfg)),
      typed: typed,
      reaching:
        if(Enum.all?(parts, & &1.reaching),
          do: Enum.reduce(parts, MapSet.new(), &MapSet.union(&2, &1.reaching))
        )
    })
  end

  # Debug-info and compile-info consumers still need the original BEAM. They
  # have their own producer query, so this does not invalidate other producers.
  defp with_chunks(db, module, producer, data)
       when producer in [
              Argus.Extractors.Generated,
              Argus.Extractors.Specs,
              Argus.Extractors.Tooling
            ] do
    {:ok, beam} = R.query(db, :module_beam, module)
    Map.put(data, :beam, Frontend.read(beam))
  end

  defp with_chunks(_, _, _, data), do: data

  defp options(db, producer) do
    source = R.untracked(fn -> R.input(db, :specs_source, :all, default: nil) end)
    [producers: [producer], trace_imprecision: true, specs_source: source]
  end

  defp producer_rows({:ok, extraction}, producer),
    do: {:ok, Map.fetch!(extraction.facts, producer)}

  @doc false
  @spec merge_rows([%{atom() => binary()}]) :: %{atom() => binary()}
  def merge_rows(parts) do
    parts
    |> Enum.reduce(%{}, fn part, rows ->
      Enum.reduce(part, rows, fn {relation, bytes}, rows ->
        Map.update(rows, relation, [bytes], &[bytes | &1])
      end)
    end)
    |> Map.new(fn {relation, chunks} ->
      # Writer escapes embedded newlines, so each complete line is a row.
      # Keep the encoded bytes instead of decoding and escaping every field.
      bytes =
        chunks
        |> Enum.flat_map(&encoded_lines/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&[&1, "\n"])
        |> IO.iodata_to_binary()

      {relation, bytes}
    end)
  end

  defp encoded_lines(""), do: []

  defp encoded_lines(bytes) do
    size = byte_size(bytes) - 1
    <<content::binary-size(size), "\n">> = bytes
    :binary.split(content, "\n", [:global])
  end
end
