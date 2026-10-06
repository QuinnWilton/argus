defmodule Argus.Graph.Identity.ProducerClosureTest do
  @moduledoc """
  A producer's rows are kept in each module's pack under the digest of
  the code it runs (`Argus.Graph.Code.closure/1`): every module it
  executes must be in its closure, or an edit to that module would leave
  stale rows in place. The closures are read from import tables; this
  runs each producer with call counting on and checks the reading
  against what executed, over a spread of the fixtures
  (`Argus.Test.FixtureSpread.spread/0`): a module a producer executes
  only for a fixture outside it goes unchecked. The producers are split
  three ways, each part in a VM of its own, so the parts run side by
  side.

  The base runs afresh, keeping the bases (`Argus.Pipeline.Base`), and
  each extractor runs over them, within its closure and without the
  emitter — a kept base holds the decoded facts, read back for the
  extractors that read them (`Argus.Pipeline.typed_readers/0`), and one
  missing from that list computes them again. An extractor run afresh is
  not counted apart: it is handed the data it is handed over a kept base
  (`Argus.Pipeline.BaseTest`), so it runs the code it runs there, beside
  the base's own, which is in every closure (`Argus.Pipeline` roots each
  one) and is counted in the base's run. (A register walk answered from
  the reaching solutions the fresh base solved, and over a kept base
  solved again, runs `Argus.Instr.Reaching`: the base's code too.)

  The closures leave the schema's modules out: a producer executes
  those outside its code key, and is keyed on the entries it read of
  them instead — which every export records
  (`Argus.Graph.Identity.SchemaReadsTest`).
  """
  use ExUnit.Case,
    async: true,
    parameterize: for(part <- 0..2, do: %{part: part, parts: 3})

  @moduletag :identity_verify
  # Minutes under a full suite's load.
  @moduletag timeout: 600_000

  alias Argus.Graph.Code
  alias Argus.Graph.Reads

  # Runs in a fresh VM: call counts are VM-wide, and this one runs other
  # tests beside it.
  @measure ~S"""
  # The code, not the fixtures it reads.
  mods =
    for app <- [:argus_beam, :beam_spy, :ctf],
        mod <- Application.spec(app, :modules) || [],
        not String.starts_with?(Atom.to_string(mod), ["Elixir.Argus.Test.", "Elixir.Inspect."]),
        do: mod

  Enum.each(mods, &Code.ensure_loaded/1)

  extract = fn beam, opts ->
    {:ok, %{status: :ok} = extraction} = Argus.Pipeline.extract_module(beam, opts)
    extraction
  end

  # The bases the extractors run over, kept untraced.
  bases = Map.new(beams, &{&1, extract.(&1, producers: [:base], keep_base: true).base})

  # Counted from here on; each producer's count starts again at zero,
  # which costs a twentieth of turning the counting off and on again.
  for m <- mods, do: :erlang.trace_pattern({m, :_, :_}, true, [:call_count])

  run = fn producer, opts ->
    :erlang.trace_pattern({:_, :_, :_}, :restart, [:call_count])

    for beam <- beams do
      extract.(beam, [producers: [producer], trace_imprecision: true] ++ opts.(beam))
    end

    Enum.filter(mods, fn m ->
      Enum.any?(m.module_info(:functions), fn {f, a} ->
        f not in [:module_info, :__info__] and
          match?({:call_count, n} when n > 0, :erlang.trace_info({m, f, a}, :call_count))
      end)
    end)
  end

  Map.new(producers, fn
    :base -> {:base, run.(:base, fn _beam -> [keep_base: true] end)}
    extractor -> {extractor, run.(extractor, &[base: bases[&1]])}
  end)
  """

  test "every module a producer executes is in its closure", %{part: part, parts: parts} do
    paths = Argus.Test.FixtureSpread.beams(Argus.Test.FixtureSpread.spread())

    producers =
      for {producer, i} <- Enum.with_index(Argus.Graph.Extraction.producers()),
          rem(i, parts) == part,
          do: producer

    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

    executed =
      try do
        # Bounded by the test's timeout, not `:peer.call/4`'s five
        # seconds, which starting the applications outlasted on a loaded
        # machine.
        :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()], :infinity)
        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:argus_beam], :infinity)
        binding = [beams: paths, producers: producers]
        {executed, _} = :peer.call(peer, Elixir.Code, :eval_string, [@measure, binding], 300_000)
        executed
      after
        :peer.stop(peer)
      end

    for producer <- producers do
      {:ok, closure} = Code.closure(producer)
      closure = MapSet.new(closure, &elem(&1, 0))
      ran = Map.fetch!(executed, producer)

      assert ran != [], "#{inspect(producer)} executed nothing"

      outside = Enum.reject(ran, &(MapSet.member?(closure, &1) or Reads.schema_module?(&1)))
      assert outside == [], "#{inspect(producer)} runs code its key does not cover"

      refute producer != :base and Argus.Pipeline.Emit in ran,
             "#{inspect(producer)} computes the decoded facts over a kept base: " <>
               "add it to Argus.Pipeline's @typed_readers"
    end
  end
end
