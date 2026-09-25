defmodule Argus.Schema do
  @moduledoc """
  Fact relation definitions for Argus analysis.

  Each relation describes a table of facts that Argus extracts from BEAM
  bytecode or domain extractors. Relations map directly to Souffle `.decl`
  declarations and `.facts` files.

  ## Layers

  - **Layer 1** — generic bytecode facts extracted from any BEAM module.
  - **Layer 2** — domain-specific facts from pluggable extractors.

  ## Reading the schema

  The schema is data, read only through the functions of this module
  and of its concern modules, each of which records the entry it
  returns (`Argus.Cache.Reads`): a producer's shard is keyed on the
  entries it read, not on this module's code (`Argus.Cache.Code`), so
  an edit to a relation no producer reads moves no shard. A new
  accessor records what it returns, as the others do —
  `Argus.SchemaReadsTest` calls every export and fails otherwise — and
  `columns/1` is the read to make when a relation's columns are all a
  caller needs: its prose is then no part of the key.
  """

  alias Argus.Cache.Reads

  @typedoc """
  The semantic kind of a relation field.

  `:symbol` and `:number` are the raw Souffle types. The richer kinds drive
  `Argus.Facts.decode/1` for in-process consumers while serializing to the
  same Souffle types (`:instr_id`/`:func_id` → `symbol`, `:label` → `number`):

  - `:instr_id` — an instruction ID (`"Mod:func/arity#idx"`), decoded to
    `Argus.InstrId.t()`.
  - `:func_id` — a function ID (`"Mod:func/arity"`), kept as a string.
  - `:label` — a BEAM label number (0 conventionally means "no label").
  """
  @type field_type :: :symbol | :number | :instr_id | :func_id | :label
  @type field :: {atom(), field_type(), String.t()}

  @type relation :: %{
          name: atom(),
          layer: 1 | 2 | 3,
          fields: [field()],
          doc: String.t()
        }

  @typedoc """
  A relation as a concern module declares it (`Argus.Schema.Bytecode` and
  its siblings): the relation, and `in_process: true` when only the
  in-process passes read it (`in_process_only/0`).
  """
  @type declaration :: %{
          required(:name) => atom(),
          required(:layer) => 1 | 2 | 3,
          required(:fields) => [field()],
          required(:doc) => String.t(),
          optional(:in_process) => true
        }

  # Bump whenever a relation is added or removed, a field changes name,
  # position, or kind, or a field's *meaning* changes. Independent of the
  # package version. `Argus.SchemaVersionTest` digests the relation shapes
  # and fails until this moves with them; every bump gets a CHANGELOG entry
  # saying what changed and who reads it. Downstream, the version rides
  # scry's and planchette's `env_fingerprint` so extraction memos never
  # outlive the encoder that wrote them.
  @schema_version 102

  # Each relation is declared once, in the module of its concern, with its
  # flags; the order of the modules and of the relations in each is the
  # order `all/0` lists them.
  @concerns [
    Argus.Schema.Bytecode,
    Argus.Schema.Supervision,
    Argus.Schema.Monitors,
    Argus.Schema.Web,
    Argus.Schema.Otp,
    Argus.Schema.Tls,
    Argus.Schema.Callbacks,
    Argus.Schema.OwnedResources,
    Argus.Schema.UnsafeInput,
    Argus.Schema.ErrorHandling,
    Argus.Schema.Distribution,
    Argus.Schema.GenStatem,
    Argus.Schema.CallValues,
    Argus.Schema.Processes,
    Argus.Schema.Dependence,
    Argus.Schema.Purity,
    Argus.Schema.Coverage,
    Argus.Schema.Priors
  ]

  @declared Enum.flat_map(@concerns, & &1.relations())

  @all_relations Enum.map(@declared, &Map.delete(&1, :in_process))
  @layer_1_relations Enum.filter(@all_relations, &(&1.layer == 1))
  @layer_2_relations Enum.filter(@all_relations, &(&1.layer == 2))
  @layer_3_relations Enum.filter(@all_relations, &(&1.layer == 3))

  # Layer-1 relations no Souffle program reads. They exist for the
  # in-process passes over a module's typed facts — `Argus.Cfg`,
  # `Argus.Dataflow`, the extractors' walks, gloss's alignment — and are
  # the bulk of the fact volume (instruction, next, def and use alone are
  # more than half of it on a large project). `Argus.Analysis.extract_facts/3`
  # leaves them out of the directory it stages; `Argus.InProcessRelationsTest`
  # fails if a rule starts reading one.
  @in_process_only for %{in_process: true, name: name} <- @declared, do: name

  @relations_by_name Map.new(@all_relations, fn r -> {r.name, r} end)

  @columns_by_name Map.new(@all_relations, fn r ->
                     {r.name, Enum.map(r.fields, fn {name, kind, _doc} -> {name, kind} end)}
                   end)

  @names Enum.map(@all_relations, & &1.name)

  # Every accessor records the entry it returns (`Argus.Cache.Reads`):
  # a producer's rows are keyed on the entries it read, not on this
  # module's code, and an accessor that returned schema data without
  # recording it would leave a stale shard in place after an edit to
  # that entry. `Argus.SchemaReadsTest` calls every export here and in
  # the concern modules, and fails unless each records a read naming
  # exactly what it returned; `reread/1` answers each read again.

  @doc """
  The fact-schema version, asserted by in-process consumers at compile time.

  Bumped whenever a relation is added/removed, any field changes name,
  position, or kind, or a field's meaning changes. Independent of the
  package version.
  """
  @spec version() :: pos_integer()
  def version, do: Reads.record("version", @schema_version)

  @doc """
  Returns all relation definitions.
  """
  @spec all() :: [relation()]
  def all, do: Reads.record("all", @all_relations)

  @doc """
  Returns layer 1 (generic bytecode) relation definitions.
  """
  @spec layer_1() :: [relation()]
  def layer_1, do: Reads.record("layer_1", @layer_1_relations)

  @doc """
  Returns layer 2 (domain extractor) relation definitions.
  """
  @spec layer_2() :: [relation()]
  def layer_2, do: Reads.record("layer_2", @layer_2_relations)

  @doc """
  Returns layer 3 (prior) relation definitions: facts a classifier
  supplies, not an extractor. See `Argus.Priors`.
  """
  @spec layer_3() :: [relation()]
  def layer_3, do: Reads.record("layer_3", @layer_3_relations)

  @doc """
  Looks up a relation by name.
  """
  @spec fetch(atom()) :: {:ok, relation()} | :error
  def fetch(name) when is_atom(name),
    do: Reads.record("fetch #{name}", Map.fetch(@relations_by_name, name))

  @doc """
  A relation's columns: each field's name and kind, in order, without
  the prose. What a reader of rows needs (`Argus.Facts.decode/1`), and
  all it depends on: an edit to a relation's documentation moves no
  key that reads only its columns.
  """
  @spec columns(atom()) :: {:ok, [{atom(), field_type()}]} | :error
  def columns(name) when is_atom(name),
    do: Reads.record("columns #{name}", Map.fetch(@columns_by_name, name))

  @doc """
  Renders a complete `.dl` declaration file for a layer.

  Every relation in the layer gets a `.decl` and a matching `.input`, so a
  rules file that includes this never has to declare a fact relation itself.
  Declaring more than a given analysis reads is free: Souffle prunes unused
  *input* relations during compilation, which is why each analysis's true
  input set (`Argus.Analysis.input_relations/1`, read out of the transformed
  RAM) stays narrow regardless of what was declared. Unused *derived*
  relations are not pruned, which is why rule fragments still have to be
  included deliberately.

  Written to disk by `mix argus.gen.dl` and checked byte-for-byte by the
  test suite. Hand-editing the generated files is the failure mode this
  exists to remove: the declarations are positional, and Souffle will not
  notice a field reordered against what the emitter actually writes.

  `layer` is `:layer_1`, `:layer_2`, `:layer_3`, or `:all`.
  """
  @spec souffle_decls(:layer_1 | :layer_2 | :layer_3 | :all) :: String.t()
  def souffle_decls(layer) when layer in [:layer_1, :layer_2, :layer_3, :all],
    do: Reads.record("souffle_decls #{layer}", render_decls(layer))

  defp render_decls(layer) do
    {relations, title, source} =
      case layer do
        :layer_1 ->
          {@layer_1_relations, "Layer 1 — generic bytecode facts", "Argus.Schema.layer_1/0"}

        :layer_2 ->
          {@layer_2_relations, "Layer 2 — domain extractor facts", "Argus.Schema.layer_2/0"}

        :layer_3 ->
          {@layer_3_relations, "Layer 3 — priors, a classifier's answers",
           "Argus.Schema.layer_3/0"}

        :all ->
          {@all_relations, "All fact relations", "Argus.Schema.all/0"}
      end

    body =
      relations
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n\n", fn rel ->
        """
        #{comment(rel.doc)}
        #{souffle_decl(rel)}
        .input #{rel.name}\
        """
      end)

    """
    // #{title}.
    //
    // GENERATED by `mix argus.gen.dl` from #{source} — do not edit.
    // Schema version #{@schema_version}.
    //
    // Include this instead of declaring fact relations by hand. Souffle
    // prunes input relations no rule reads, so including the whole layer
    // costs nothing in the solve.

    #{body}
    """
  end

  defp souffle_decl(rel) do
    fields_str =
      Enum.map_join(rel.fields, ", ", fn {fname, ftype, _doc} ->
        "#{fname}: #{souffle_type(ftype)}"
      end)

    ".decl #{rel.name}(#{fields_str})"
  end

  # Relation docs are prose and frequently run to several lines. Every line
  # needs its own `//`, or the second line lands in the parser as a bare
  # identifier and the whole program fails to compile.
  defp comment(doc) do
    doc
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> "//"
      line -> "// " <> line
    end)
  end

  defp souffle_type(:symbol), do: :symbol
  defp souffle_type(:instr_id), do: :symbol
  defp souffle_type(:func_id), do: :symbol
  defp souffle_type(:number), do: :number
  defp souffle_type(:label), do: :number

  @doc """
  Returns all relation names.
  """
  @spec names() :: [atom()]
  def names, do: Reads.record("names", @names)

  @doc """
  Relations that only the in-process passes read; no Souffle program does.
  """
  @spec in_process_only() :: [atom()]
  def in_process_only, do: Reads.record("in_process_only", @in_process_only)

  @doc """
  What `read` (`t:Argus.Cache.Reads.read/0`) names now: the answer the
  accessor that recorded it gives today, asked again (and recorded
  again). How a store checks the reads a producer made
  (`Argus.Cache.Reads.digest/1`); a read no accessor makes names
  `{:unknown_read, read}`.

  A read's relation name that is no atom in this VM names no relation:
  every relation's name is an atom of this module's literals, made when
  it was loaded.
  """
  @spec reread(Reads.read()) :: term()
  def reread(read) when is_binary(read) do
    case String.split(read, " ", parts: 2) do
      ["version"] -> version()
      ["all"] -> all()
      ["layer_1"] -> layer_1()
      ["layer_2"] -> layer_2()
      ["layer_3"] -> layer_3()
      ["names"] -> names()
      ["in_process_only"] -> in_process_only()
      ["fetch", name] -> by_name(read, name, &fetch/1)
      ["columns", name] -> by_name(read, name, &columns/1)
      ["souffle_decls", layer] -> reread_decls(read, layer)
      ["relations", module] -> reread_concern(read, module)
      _ -> {:unknown_read, read}
    end
  end

  defp by_name(read, name, accessor) do
    accessor.(String.to_existing_atom(name))
  rescue
    ArgumentError -> Reads.record(read, :error)
  end

  defp reread_decls(read, layer) do
    case Enum.find([:layer_1, :layer_2, :layer_3, :all], &(Atom.to_string(&1) == layer)) do
      nil -> {:unknown_read, read}
      layer -> souffle_decls(layer)
    end
  end

  defp reread_concern(read, module) do
    case Enum.find(@concerns, &(Atom.to_string(&1) == module)) do
      nil -> {:unknown_read, read}
      concern -> concern.relations()
    end
  end
end
