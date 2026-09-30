defmodule Argus.Graph.ModuleTrace do
  @moduledoc false

  alias Argus.Graph.{Captures, FunctionPack, Functions}
  alias Roux.{Blob, Database, Dependencies, Memo}
  alias Roux.Blob.Trace
  alias Roux.Runtime, as: R

  @spec fetch(Database.t(), term(), atom(), term(), Dependencies.token(), (-> result)) :: result
        when result: term()
  def fetch(db, module, kind, identity, token, compute) do
    name = {:argus_function_module, 1, Blob.term_digest(identity)}

    hit =
      if token do
        Enum.find_value(Trace.fetch(db.blob, name, limit: 4), fn trace ->
          with %{pack: pack, held: held, codes: codes} <- trace.value,
               true <- Enum.all?(codes, fn {q, v} -> R.query_code(db, q) == v end),
               true <- Enum.all?(trace.deps, fn {read, value} -> observe(db, read) === value end),
               true <- Enum.all?(held, &Blob.member?(db.blob, &1)),
               ^token <- Dependencies.snapshot(db),
               :ok <- Trace.mark_used(trace) do
            {:ok, pack, held}
          else
            _ -> nil
          end
        end)
      end

    hit || store(db, module, kind, name, token, compute)
  end

  defp store(db, module, kind, name, token, compute) do
    result = compute.()

    # Nested query hooks keep separate read sets. Walk their completed memos
    # to retain every schema/spec observation, without copying fact values.
    with {:ok, %{lost: false} = pack, held} <- result,
         true <- token != nil,
         {:ok, reads, codes} <- frontier(db, module, [{:extraction_segments, {module, kind}}]),
         observed = for(read <- Enum.sort(Map.keys(reads)), do: {read, observe(db, read)}),
         true <- Enum.all?(codes, fn {query, version} -> R.query_code(db, query) == version end),
         ^token <- Dependencies.snapshot(db) do
      Trace.put(db.blob, name, observed, %{pack: pack, held: held, codes: Enum.sort(codes)},
        keep: 4
      )
    end

    result
  end

  defp frontier(db, module, keys), do: walk(db, module, keys, %{}, %{}, %{})

  defp walk(_db, _module, [], _seen, reads, codes), do: {:ok, reads, codes}

  defp walk(db, module, [key | rest], seen, reads, codes) do
    if Map.has_key?(seen, key) do
      walk(db, module, rest, seen, reads, codes)
    else
      next(db, module, key, rest, Map.put(seen, key, true), reads, codes)
    end
  end

  # These values already participate in the enclosing trace's identity and
  # live dependencies. Stop at the frontend contract, including custom ones.
  defp next(db, module, {query, module}, rest, seen, reads, codes)
       when query in [:module_beam, :module_name],
       do: walk(db, module, rest, seen, reads, codes)

  defp next(db, module, {:producer_code, :all}, rest, seen, reads, codes),
    do: walk(db, module, rest, seen, reads, codes)

  defp next(db, module, {:parallel, _, keys}, rest, seen, reads, codes),
    do: walk(db, module, keys ++ rest, seen, reads, codes)

  defp next(db, module, {query, key}, rest, seen, reads, codes)
       when query in [:schema_entry, :installed_specs] do
    read = if query == :installed_specs, do: {query, Atom.to_string(key)}, else: {query, key}
    walk(db, module, rest, seen, Map.put(reads, read, true), codes)
  end

  defp next(db, module, {kind, name, key}, rest, seen, reads, codes)
       when kind in [:input, :input_absent],
       do: walk(db, module, rest, seen, Map.put(reads, {:input, name, key}, true), codes)

  defp next(db, module, {query, _} = key, rest, seen, reads, codes) do
    with %{module: owner} when owner in [Functions, Captures, FunctionPack] <-
           Database.query_definition(db, query),
         {:ok, deps, code, persist, generation}
         when persist in [:inline, :blob] and is_binary(code) <-
           Memo.trace_state(db, key),
         true <- code == Database.code_version(db, query),
         :clean <- Dependencies.status(db, key),
         ^generation <- Memo.generation(db, key) do
      walk(db, module, deps ++ rest, seen, reads, Map.put(codes, query, code))
    else
      _ -> :unavailable
    end
  end

  # An unfamiliar dependency must remain on the ordinary graph path.
  defp next(_db, _module, _key, _rest, _seen, _reads, _codes), do: :unavailable

  defp observe(db, {:installed_specs, name}),
    do: R.query(db, :installed_specs, String.to_atom(name))

  defp observe(db, {query, key}), do: R.query(db, query, key)

  defp observe(db, {:input, name, key}) do
    absent = make_ref()

    case R.input(db, name, key, default: absent) do
      ^absent -> :absent
      value -> {:present, Blob.term_digest(value)}
    end
  end
end
