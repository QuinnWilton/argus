defmodule Argus.Graph.ExtractionCache do
  @moduledoc false

  alias Argus.Graph.Reads
  alias Roux.Blob
  alias Roux.Blob.Trace

  @traces Roux.Blob.Trace.Pack

  @spec fetch(Roux.Database.t(), term(), term(), term(), (-> {:ok, map()})) :: {:ok, map()}
  def fetch(db, module, kind, identity, compute) do
    grouped(db, module, fn -> fetch_trace(db, module, kind, identity, compute) end)
  end

  defp grouped(db, module, run) do
    # This chooses a storage partition; the trace identity covers the data.
    name = Roux.Runtime.untracked(fn -> Roux.Runtime.query(db, :module_name, module) end)
    Roux.Blob.Trace.Pack.with_group(db.blob, {:argus_extraction, name}, run, write: :loose)
  end

  defp fetch_trace(db, module, kind, identity, compute) do
    # Graph-side preparation can change without changing the producer itself.
    # A content trace must cover the enclosing query's code as well.
    identity = {Roux.Runtime.code_version(), identity}
    name = {:argus_extraction, 3, kind, Blob.term_digest(identity)}

    hit =
      Enum.find_value(@traces.fetch(db.blob, name, limit: 4), fn trace ->
        with true <- Enum.all?(trace.deps, fn {read, value} -> observe(db, read) === value end),
             :ok <- Trace.mark_used(trace) do
          {:ok, trace.value}
        else
          _ -> nil
        end
      end)

    hit || store(db, module, kind, name, compute)
  end

  defp store(db, module, kind, name, compute) do
    :telemetry.execute([:argus, :graph, :extraction_compute], %{count: 1}, %{
      database: Roux.Database.id(db),
      module: Roux.Runtime.untracked(fn -> Roux.Runtime.query(db, :module_name, module) end),
      producer: kind,
      name: name
    })

    {{:ok, result}, schema} = Argus.Schema.Reads.track(compute)

    dependencies =
      for(
        read <- (Enum.concat(Map.values(result.reads)) ++ schema) |> Enum.uniq(),
        do: {:schema, read}
      ) ++
        for(module <- result.installed, do: {:installed, Atom.to_string(module)})

    observed = for read <- Enum.sort(dependencies), do: {read, observe(db, read)}
    # A function's rows are small. Keep them in the compressed trace rather
    # than writing and reading a second file for each producer/function pair.
    result = Map.drop(result, [:reads, :installed])
    :ok = @traces.put(db.blob, name, observed, result, keep: 4)
    {:ok, result}
  end

  defp observe(db, {:schema, read}), do: Reads.schema_entry(db, read)
  defp observe(db, {:installed, name}), do: Reads.installed_specs(db, String.to_atom(name))
end
