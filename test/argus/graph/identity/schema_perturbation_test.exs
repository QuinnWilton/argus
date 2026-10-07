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
  use Argus.Test.Peer

  alias Argus.Test.FixtureSpread
  alias Argus.Test.Peer

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  @probe :schema_perturbation_probe

  test "a producer's rows do not move with any schema entry it did not read" do
    beams = FixtureSpread.beams(FixtureSpread.all())
    producers = Argus.Graph.Extraction.producers()

    # The rows here are extracted in a VM set up as the perturbed one is,
    # so that nothing but the schema tells them apart: not the modules
    # another test compiled into this one, nor its code path.
    {here, digests} =
      Peer.run(peer!(), fn ->
        here = extract(beams, producers)
        reads = here.reads |> Map.values() |> Enum.concat() |> Enum.uniq()
        {here, digests(reads)}
      end)

    assert Enum.all?(producers, &(Map.fetch!(here.reads, &1) != [])),
           "a producer read nothing of the schema: the decoded facts should be read"

    # The producers that read the same entries are checked together.
    for {reads, group} <- Enum.group_by(producers, &Map.fetch!(here.reads, &1)) do
      check_group(beams, group, reads, Map.take(digests, reads), here)
    end
  end

  defp check_group(beams, group, reads, digests, here) do
    peer = peer!()
    perturbation = perturbed(reads)
    :ok = Peer.run(peer, fn -> install!(perturbation) end)

    # The perturbed schema is the one the peer answers with.
    names = for {_mod, _read, rels} <- perturbation.modules, rel <- rels, do: rel.name
    assert Enum.sort(Peer.run(peer, &Argus.Schema.names/0)) == Enum.sort(names)

    there = Peer.run(peer, fn -> extract(beams, group) end)

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
    assert Peer.run(peer, fn -> digests(reads) end) == digests

    # And a read it made, changed, moves its key.
    case Enum.find(reads, &String.starts_with?(&1, "columns ")) do
      nil ->
        :ok

      "columns " <> name = read ->
        changed = perturbed(reads, String.to_existing_atom(name))
        :ok = Peer.run(peer, fn -> install!(changed) end)
        moved = Peer.run(peer, fn -> digests(reads) end)
        assert moved[read] != digests[read]
        assert Map.delete(moved, read) == Map.delete(digests, read)
    end
  end

  # A fresh VM on this one's code path, exactly, running argus: the rows
  # here and there are extracted in VMs set up alike.
  defp peer! do
    peer = Peer.start!(code_path: :this)
    {:ok, _} = Peer.run(peer, fn -> Application.ensure_all_started(:argus_beam) end)
    peer
  end

  # ── In the peer ─────────────────────────────────────────────────────

  # Installs the perturbed concern modules and compiles `Argus.Schema`
  # again over them.
  defp install!(%{modules: concerns}) do
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

    schema_file = List.to_string(Argus.Schema.module_info(:compile)[:source])
    Code.compile_string(File.read!(schema_file), schema_file)
    :ok
  end

  # Each module extracted afresh: every producer's rows per module, in
  # `beams`' order, and what each read. Digests, not the rows: they cross
  # the peer's standard I/O.
  defp extract(beams, producers) do
    extractions =
      beams
      |> Task.async_stream(
        fn beam ->
          {:ok, %{status: :ok} = extraction} =
            Argus.Pipeline.extract_module(beam, producers: producers, trace_imprecision: true)

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
          reads = extractions |> Enum.flat_map(& &1.reads[producer]) |> Enum.uniq()
          {producer, Enum.sort(reads)}
        end),
      rows: Map.new(producers, &{&1, Enum.map(extractions, fn e -> e.rows[&1] end)})
    }
  end

  defp digests(reads), do: Map.new(reads, &{&1, Argus.Graph.Reads.entry_digest(&1)})

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

        ["datalog_decls", _layer] ->
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
