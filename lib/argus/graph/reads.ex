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
  the code path (`Argus.Specs.installed/2`). The extraction cache
  (`Argus.Graph.ExtractionCache`) keeps what it read, and a cached
  extraction depends on `installed_specs(module)` for each: a digest of
  what reading that module's specs can give
  (`Argus.Specs.interface_digest/1`), which reads the input that moves
  when its beam does — the program's own `beam`, or the `app_code` of
  the directory it lives in (`code_index`). A dependency rebuilt without
  a change to its specs or types re-extracts nothing; a spec that
  changes re-extracts exactly the modules that read it.
  """

  use Roux.Query, code: true

  alias Argus.Schema
  alias Roux.Runtime

  @doc """
  Whether `module` is schema data: `Argus.Schema` or a module under it,
  but `Argus.Schema.Reads`, which records and holds no entry. What
  every query's code version leaves out (walking through it, so what it
  calls is still covered), being keyed on the entries it read instead.
  """
  @spec schema_module?(module()) :: boolean()
  def schema_module?(Argus.Schema), do: true

  # The recorder is code: what it records is what every reader is keyed
  # on, and a change to it moves them.
  def schema_module?(Argus.Schema.Reads), do: false

  def schema_module?(module) when is_atom(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.Argus.Schema.")

  @doc """
  The digest of what `read` names now (`Argus.Schema.reread/1`):
  SHA-256 of its deterministic external term, as lowercase hex. What
  `schema_entry` answers for the read.
  """
  @spec entry_digest(Schema.Reads.read()) :: String.t()
  def entry_digest(read) when is_binary(read) do
    value = Schema.reread(read)

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The `around:` hook of every query of the graph: runs `body` with a set
  of schema reads of its own, and makes the running query depend on
  each (`schema_entry`). A query demanded inside `body` records into its
  own set, not this one: what it read, the caller depends on through it.
  """
  @spec around(map(), (-> result)) :: result when result: term()
  def around(%{db: db}, body) do
    {result, reads} = Schema.Reads.isolated(body)

    # In a set of their own, dropped: digesting an entry reads it again,
    # and that read is this query's edge, not its caller's.
    {:ok, _} =
      Schema.Reads.isolated(fn ->
        Enum.each(reads, &schema_entry(db, &1))
        :ok
      end)

    result
  end

  # One entry of the schema, by the name its accessor recorded it under
  # (`"columns call_arg"`, `"fetch supervisor"`): the digest of what the
  # entry is now. Versioned by the schema's code, as nothing else here is.
  defquery :schema_entry, key: read, returns: String.t() do
    entry_digest(read)
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
