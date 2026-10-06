defmodule Argus.Graph.Identity.SchemaPerturbationTest do
  @moduledoc """
  A producer's rows are kept on the schema entries it recorded reading
  (`schema_entry`, `Argus.Graph.Reads`), not on the schema's code.
  `Argus.Graph.Identity.SchemaReadsTest` checks that every accessor
  records what it returns; this checks the claim itself, whatever path
  the data took: each producer runs over every fixture
  (`Argus.Test.FixtureSpread.all/0`) in a VM of its own whose schema has
  every entry it did not read changed — its fields renamed and retyped,
  a field added, its documentation, its in-process flag and its layer
  changed, relations reordered, one removed and one added — and its rows
  must come out byte for byte as they do here. A producer that read the
  schema some way that records nothing (memoized it, smuggled it out of
  a module attribute, read it in another process) fails here.

  The rows are computed afresh. Over a kept base a producer is handed
  the data it is handed afresh (`Argus.Pipeline.BaseTest`), and a kept
  base holds no schema, so its rows there are these.

  And the other way: in that VM, the reads it recorded digest as they do
  here (the perturbation moves none of its keys), and once one of them
  is changed too, that read's digest moves.
  """
  use ExUnit.Case, async: true

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  @probe :schema_perturbation_probe

  # Runs in a fresh VM: installs the perturbed concern modules and
  # compiles `Argus.Schema` again over them, then extracts.
  @install ~S"""
  Code.put_compiler_option(:ignore_module_conflict, true)

  # Most concerns are unchanged when the final check moves one column.
  # Keep their installed definitions; Schema still recompiles over the
  # complete set below, including the one concern that did move.
  for {mod, read, relations} <- concerns, mod.relations() != relations do
    Code.compile_quoted(
      quote do
        defmodule unquote(mod) do
          def relations,
            do: Argus.Schema.Reads.record(unquote(read), unquote(Macro.escape(relations)))
        end
      end
    )
  end

  Code.compile_string(schema_source, schema_file)
  :ok
  """

  # Each module extracted afresh: every producer's rows per module, in
  # `beams`' order, and what each read.
  @extract ~S"""
  extractions =
    beams
    |> Task.async_stream(
      fn beam ->
        {:ok, %{status: :ok} = extraction} =
          Argus.Pipeline.extract_module(beam, producers: producers, trace_imprecision: true)

        # Digests, not the rows: they cross the peer's standard I/O.
        rows =
          Map.new(extraction.facts, fn {producer, rows} ->
            {producer, :crypto.hash(:sha256, :erlang.term_to_binary(rows, [:deterministic]))}
          end)

        %{rows: rows, reads: extraction.reads}
      end,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, extraction} -> extraction end)

  %{
    reads:
      Map.new(producers, fn producer ->
        {producer, extractions |> Enum.flat_map(& &1.reads[producer]) |> Enum.uniq() |> Enum.sort()}
      end),
    rows: Map.new(producers, fn producer -> {producer, Enum.map(extractions, & &1.rows[producer])} end)
  }
  """

  @digests ~S"""
  Map.new(reads, &{&1, Argus.Graph.Reads.entry_digest(&1)})
  """

  test "a producer's rows do not move with any schema entry it did not read" do
    beams = Argus.Test.FixtureSpread.beams(Argus.Test.FixtureSpread.all())
    producers = Argus.Graph.Extraction.producers()

    # The rows here are extracted in a VM set up as the perturbed one is,
    # so that nothing but the schema tells them apart: not the modules
    # another test compiled into this one, nor its code path.
    {here, digests} =
      with_peer(fn peer ->
        here = eval(peer, @extract, beams: beams, producers: producers)
        reads = here.reads |> Map.values() |> Enum.concat() |> Enum.uniq()
        {here, eval(peer, @digests, reads: reads)}
      end)

    assert Enum.all?(producers, &(Map.fetch!(here.reads, &1) != [])),
           "a producer read nothing of the schema: the decoded facts should be read"

    # The producers that read the same entries are checked together.
    for {reads, group} <- Enum.group_by(producers, &Map.fetch!(here.reads, &1)) do
      check_group(beams, group, reads, Map.take(digests, reads), here)
    end
  end

  defp check_group(beams, group, reads, digests, here) do
    with_peer(fn peer ->
      perturbation = perturbed(reads)
      :ok = eval(peer, @install, install(perturbation))

      # The perturbed schema is the one the peer answers with.
      names = for {_mod, _read, rels} <- perturbation.modules, rel <- rels, do: rel.name
      assert Enum.sort(eval(peer, "Argus.Schema.names()", [])) == Enum.sort(names)

      there = eval(peer, @extract, beams: beams, producers: group)

      for {producer, rows} <- there.rows do
        moved =
          for {beam, there, here} <- Enum.zip([beams, rows, here.rows[producer]]),
              there != here,
              do: Path.basename(beam, ".beam")

        assert moved == [],
               "#{inspect(producer)}'s rows moved with schema entries it did not " <>
                 "record reading (it recorded #{inspect(reads)}), in #{inspect(moved)}"
      end

      for producer <- group, do: assert(Map.fetch!(there.reads, producer) == reads)

      # Nothing it read moved, so neither did its key.
      assert eval(peer, @digests, reads: reads) == digests

      # And a read it made, changed, moves its key.
      case Enum.find(reads, &String.starts_with?(&1, "columns ")) do
        nil ->
          :ok

        "columns " <> name = read ->
          changed = perturbed(reads, String.to_existing_atom(name))
          :ok = eval(peer, @install, install(changed))
          moved = eval(peer, @digests, reads: reads)
          assert moved[read] != digests[read]
          assert Map.delete(moved, read) == Map.delete(digests, read)
      end
    end)
  end

  # A fresh VM on this one's code path, exactly: Mix leaves off it the
  # OTP applications argus does not depend on, which a peer's own path
  # holds, and the specs extractor reads what the path holds.
  defp with_peer(fun) do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

    try do
      # Bounded by the test's timeout: `:peer.call/4`'s five seconds is
      # less than starting argus's applications took in a peer on a loaded
      # machine, though the start does no work of argus's own.
      true = :peer.call(peer, :code, :set_path, [:code.get_path()], :infinity)
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:argus_beam], :infinity)
      fun.(peer)
    after
      :peer.stop(peer)
    end
  end

  # Only the value comes back: the peer's connection is its standard
  # I/O, and the script's binding holds every module's extraction.
  defp eval(peer, script, binding) do
    only_value = "elem(Code.eval_string(script, binding), 0)"
    args = [only_value, [script: script, binding: binding]]
    {value, _binding} = :peer.call(peer, Elixir.Code, :eval_string, args, 600_000)
    value
  end

  defp install(%{modules: modules}) do
    schema_file = Argus.Schema.module_info(:compile)[:source] |> List.to_string()
    [concerns: modules, schema_file: schema_file, schema_source: File.read!(schema_file)]
  end

  # ── The perturbation ────────────────────────────────────────────────

  # Every concern module with its relations changed wherever `reads`
  # leaves them free — and, when `also` names a relation, its columns
  # too: `%{modules: [{mod, read, relations}]}`.
  defp perturbed(reads, also \\ nil) do
    cover = coverage(reads)
    cover = %{cover | columns: MapSet.delete(cover.columns, also)}

    modules =
      for mod <- concerns() do
        relations =
          if MapSet.member?(cover.concerns, mod) do
            mod.relations()
          else
            mod.relations()
            |> Enum.map(&perturb(&1, cover, also))
            |> reshape(cover, mod)
          end

        {mod, "relations #{mod}", relations}
      end

    probe? =
      Enum.any?(modules, fn {_mod, _read, relations} ->
        Enum.any?(relations, &(&1.name == @probe))
      end)

    assert probe? or cover.membership, "the perturbation added no relation"
    %{modules: modules}
  end

  defp concerns do
    for mod <- Application.spec(:argus_beam, :modules),
        Argus.Graph.Reads.schema_module?(mod),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :relations, 0),
        do: mod
  end

  # What the reads hold still: whole relations, relations' columns, the
  # set and order of the relations, the in-process flags, whole concern
  # modules.
  defp coverage(reads) do
    base = %{
      whole: MapSet.new(),
      columns: MapSet.new(),
      membership: false,
      flags: false,
      concerns: MapSet.new()
    }

    Enum.reduce(reads, base, fn read, cover ->
      case String.split(read, " ", parts: 2) do
        ["names"] ->
          %{cover | membership: true}

        ["in_process_only"] ->
          %{cover | flags: true, membership: true}

        ["all"] ->
          whole(%{cover | membership: true}, Argus.Schema.all())

        ["layer_" <> n] ->
          layer = String.to_integer(n)

          whole(
            %{cover | membership: true},
            Enum.filter(Argus.Schema.all(), &(&1.layer == layer))
          )

        ["souffle_decls", _layer] ->
          whole(%{cover | membership: true}, Argus.Schema.all())

        ["fetch", name] ->
          %{cover | whole: MapSet.put(cover.whole, String.to_existing_atom(name))}

        ["columns", name] ->
          %{cover | columns: MapSet.put(cover.columns, String.to_existing_atom(name))}

        ["relations", mod] ->
          mod = String.to_existing_atom(mod)

          whole(
            %{cover | membership: true, flags: true, concerns: MapSet.put(cover.concerns, mod)},
            mod.relations()
          )
      end
    end)
  end

  defp whole(cover, relations),
    do: %{cover | whole: Enum.into(Enum.map(relations, & &1.name), cover.whole)}

  defp perturb(relation, cover, also) do
    cond do
      MapSet.member?(cover.whole, relation.name) and relation.name != also ->
        relation

      MapSet.member?(cover.columns, relation.name) ->
        relation |> prose() |> flag(cover) |> layer(cover)

      true ->
        relation |> prose() |> flag(cover) |> layer(cover) |> columns()
    end
  end

  defp prose(relation) do
    fields = for {name, kind, doc} <- relation.fields, do: {name, kind, doc <> " (perturbed)"}
    %{relation | doc: "Perturbed. " <> relation.doc, fields: fields}
  end

  defp flag(relation, %{flags: true}), do: relation

  defp flag(relation, _cover) do
    if Map.get(relation, :in_process),
      do: Map.delete(relation, :in_process),
      else: Map.put(relation, :in_process, true)
  end

  defp layer(relation, %{membership: true}), do: relation
  defp layer(%{layer: 1} = relation, _cover), do: %{relation | layer: 2}
  defp layer(%{layer: 2} = relation, _cover), do: %{relation | layer: 1}
  defp layer(relation, _cover), do: relation

  defp columns(relation) do
    fields =
      for {name, kind, doc} <- relation.fields do
        {:"#{name}_perturbed", retype(kind), doc}
      end

    %{relation | fields: fields ++ [{:perturbed, :number, "an added column"}]}
  end

  defp retype(:symbol), do: :number
  defp retype(:number), do: :symbol
  defp retype(:instr_id), do: :label
  defp retype(:label), do: :instr_id
  defp retype(:func_id), do: :number

  # Reversed, the last relation no read names removed, and a relation
  # added — unless a read holds the set of relations still.
  defp reshape(relations, %{membership: true}, _mod), do: relations

  defp reshape(relations, cover, mod) do
    free =
      Enum.reject(relations, fn relation ->
        MapSet.member?(cover.whole, relation.name) or MapSet.member?(cover.columns, relation.name)
      end)

    relations =
      case {free, relations} do
        {[_ | _], [_, _ | _]} -> relations -- [List.last(free)]
        _ -> relations
      end

    added =
      if mod == hd(concerns()),
        do: [%{name: @probe, layer: 2, fields: [{:x, :symbol, "probe"}], doc: "A probe."}],
        else: []

    Enum.reverse(relations) ++ added
  end
end
