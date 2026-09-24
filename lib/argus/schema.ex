defmodule Argus.Schema do
  @moduledoc """
  Fact relation definitions for Argus analysis.

  Each relation describes a table of facts that Argus extracts from BEAM
  bytecode or domain extractors. Relations map directly to Souffle `.decl`
  declarations and `.facts` files.

  ## Layers

  - **Layer 1** — generic bytecode facts extracted from any BEAM module.
  - **Layer 2** — domain-specific facts from pluggable extractors.
  """

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
  @schema_version 78

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

  @doc """
  The fact-schema version, asserted by in-process consumers at compile time.

  Bumped whenever a relation is added/removed, any field changes name,
  position, or kind, or a field's meaning changes. Independent of the
  package version.
  """
  @spec version() :: pos_integer()
  def version, do: @schema_version

  @doc """
  Returns all relation definitions.
  """
  @spec all() :: [relation()]
  def all, do: @all_relations

  @doc """
  Returns layer 1 (generic bytecode) relation definitions.
  """
  @spec layer_1() :: [relation()]
  def layer_1, do: @layer_1_relations

  @doc """
  Returns layer 2 (domain extractor) relation definitions.
  """
  @spec layer_2() :: [relation()]
  def layer_2, do: @layer_2_relations

  @doc """
  Returns layer 3 (prior) relation definitions: facts a classifier
  supplies, not an extractor. See `Argus.Priors`.
  """
  @spec layer_3() :: [relation()]
  def layer_3, do: @layer_3_relations

  @doc """
  Looks up a relation by name.
  """
  @spec fetch(atom()) :: {:ok, relation()} | :error
  def fetch(name) do
    case @relations_by_name do
      %{^name => rel} -> {:ok, rel}
      _ -> :error
    end
  end

  defp souffle_decl(name) do
    rel = Map.fetch!(@relations_by_name, name)

    fields_str =
      rel.fields
      |> Enum.map_join(", ", fn {fname, ftype, _doc} -> "#{fname}: #{souffle_type(ftype)}" end)

    ".decl #{name}(#{fields_str})"
  end

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
  def souffle_decls(layer) do
    {relations, title, source} =
      case layer do
        :layer_1 ->
          {layer_1(), "Layer 1 — generic bytecode facts", "Argus.Schema.layer_1/0"}

        :layer_2 ->
          {layer_2(), "Layer 2 — domain extractor facts", "Argus.Schema.layer_2/0"}

        :layer_3 ->
          {layer_3(), "Layer 3 — priors, a classifier's answers", "Argus.Schema.layer_3/0"}

        :all ->
          {all(), "All fact relations", "Argus.Schema.all/0"}
      end

    body =
      relations
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n\n", fn rel ->
        """
        #{comment(rel.doc)}
        #{souffle_decl(rel.name)}
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
  def names, do: Enum.map(@all_relations, & &1.name)

  @doc """
  Relations that only the in-process passes read; no Souffle program does.
  """
  @spec in_process_only() :: [atom()]
  def in_process_only, do: @in_process_only
end
