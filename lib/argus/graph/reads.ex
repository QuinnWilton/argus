defmodule Argus.Graph.Reads do
  @moduledoc """
  What a query read outside its code and its inputs, turned into edges
  of the graph: the entries of argus's schema, and the specs of modules
  on the code path.

  ## The schema

  `Argus.Schema` and its concern modules are data compiled into argus:
  every relation's declaration, as literals. Keyed as code, an edit to
  any relation would move every query that reads one. Each query here
  leaves them out of its code version instead (`schema_module?/1`), and
  each accessor of the schema records the entry it returned
  (`Argus.Schema.Reads`): `around/2` runs every query body inside a set
  of its own and, when the body returns, demands `schema_entry(read)`
  for each read it recorded. `schema_entry` is the entry's digest now;
  it is the one query versioned by the schema's code, so an argus edit
  digests again the entries read so far, backdating the ones that came
  out equal, and a moved entry re-runs exactly the queries that read it.

  So a query reads the schema only through its accessors, and never
  keeps what one returned anywhere another query could find it; and the
  narrowest accessor is the one to call (`Argus.Schema.columns/1`, not
  `names/0`, which moves with any relation added).

  ## Specs on the code path

  Extraction reads the specs of every remote module a module calls from
  the code path (`Argus.Specs.installed/2`). What it read is recorded
  (`record_installed/1`), and `around/2` demands `installed_specs(module)`
  for each: a digest of what reading that module's specs can give
  (`Argus.Specs.interface_digest/1`), which reads the input that moves
  when its beam does — the program's own `beam`, or the `app_code` of
  the directory it lives in (`code_index`). A dependency rebuilt without
  a change to its specs or types re-extracts nothing; a spec that
  changes re-extracts exactly the modules that read it.
  """

  use Roux.Query, code: true

  alias Argus.Schema
  alias Roux.Runtime

  @installed_key {__MODULE__, :installed}

  @doc """
  Whether `module` is schema data (`Argus.Cache.Code.schema_module?/1`):
  what every query's code version leaves out, being keyed on the
  entries it read instead.
  """
  @spec schema_module?(module()) :: boolean()
  def schema_module?(module), do: Argus.Cache.Code.schema_module?(module)

  @doc """
  The `around:` hook of every query of the graph: runs `body` with a set
  of schema reads and of installed-spec reads of its own, and makes the
  running query depend on each (`schema_entry`, `installed_specs`). A
  query demanded inside `body` records into its own sets, not this one:
  what it read, the caller depends on through it.
  """
  @spec around(map(), (-> result)) :: result when result: term()
  def around(%{db: db}, body) do
    outer = Process.put(@installed_key, %{})

    {{result, reads}, installed} =
      try do
        read = Schema.Reads.isolated(body)
        {read, Process.get(@installed_key, %{})}
      after
        restore(outer)
      end

    # In a set of their own, dropped: digesting an entry reads it again,
    # and that read is this query's edge, not its caller's.
    {:ok, _} =
      Schema.Reads.isolated(fn ->
        Enum.each(reads, &schema_entry(db, &1))
        installed |> Map.keys() |> Enum.sort() |> Enum.each(&installed_specs(db, &1))
        :ok
      end)

    result
  end

  defp restore(nil), do: Process.delete(@installed_key)
  defp restore(outer), do: Process.put(@installed_key, outer)

  @doc """
  Records that the running query read the specs of `modules` from the
  code path (made in another process on its behalf, as extraction's
  are): `around/2` turns each into an edge.
  """
  @spec record_installed([module()]) :: :ok
  def record_installed(modules) when is_list(modules) do
    case Process.get(@installed_key) do
      nil -> :ok
      set -> Process.put(@installed_key, Enum.reduce(modules, set, &Map.put(&2, &1, true)))
    end

    :ok
  end

  # One entry of the schema, by the name its accessor recorded it under
  # (`"columns call_arg"`, `"fetch supervisor"`): the digest of what the
  # entry is now. Versioned by the schema's code, as nothing else here is.
  defquery :schema_entry, key: read, returns: String.t() do
    Argus.Cache.Reads.digest(read)
  end

  # What reading `module`'s specs gives, as a digest, depending on the
  # input that moves when its beam does. Where the module lives is the
  # specs source's to say (`Argus.Specs.Source`: the project's ebins and
  # the installed OTP), or the code path's without one; both are
  # inputs, so a module appearing or leaving is seen.
  defquery :installed_specs, key: module, returns: String.t() do
    source = Runtime.input(db, :specs_source, :all, default: nil)
    index = Runtime.input(db, :code_index, :all, default: %{})

    case where(module, source) do
      {:path, path} ->
        case Runtime.input(db, :beam, path, default: nil) do
          nil ->
            case Map.fetch(index, Path.dirname(path)) do
              {:ok, name} -> _ = Runtime.input(db, :app_code, name, default: nil)
              :error -> :runtime
            end

          %{} ->
            :program
        end

        interface(db, module, path, source)

      :runtime ->
        runtime_interface(db, module, source)

      :absent ->
        "absent"
    end
  end

  defp where(module, nil) do
    case :code.which(module) do
      path when is_list(path) -> {:path, List.to_string(path)}
      :non_existing -> :absent
      _preloaded_or_in_memory -> :runtime
    end
  end

  defp where(module, source) do
    case Argus.Specs.Source.which(source, module) do
      {:ok, :runtime} -> :runtime
      {:ok, path} -> {:path, Path.expand(path)}
      :error -> :absent
    end
  end

  # A module the runtime carries (preloaded, as `:erlang` is, or loaded
  # from no file): its digest kept under the digest of its loaded code,
  # which moves with any other code of it. `:erlang`'s specs are read on
  # every run, and fetching them is most of a warm run's specs work.
  defp runtime_interface(db, module, source) do
    if :erlang.module_loaded(module) do
      Roux.Stamp.memo(
        {__MODULE__, :runtime_interface, module, module.module_info(:md5)},
        [],
        fn -> Argus.Specs.interface_digest(module, source) end,
        store: db.blob
      )
    else
      Argus.Specs.interface_digest(module, source)
    end
  end

  # A module's interface digest, kept across VMs under the stamp of the
  # file it is read from: a fresh VM whose beams have not moved stats
  # them rather than decoding their debug info.
  defp interface(db, module, path, source) do
    Roux.Stamp.memo(
      {__MODULE__, :interface, module, path},
      [path],
      fn -> Argus.Specs.interface_digest(module, source) end,
      store: db.blob
    )
  end
end
