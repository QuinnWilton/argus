defmodule Argus.Cache.CodeClosureTest do
  @moduledoc """
  A producer's shard is keyed on the code it runs (`Argus.Cache.Code`):
  every module it executes must be in its closure, or an edit to that
  module would leave a stale shard in place. The closures are read from
  import tables; this runs each producer with call counting on and
  checks the reading against what executed. The producers are split
  three ways, each part in a VM of its own, so the parts run side by
  side.

  The kept bases (`Argus.Pipeline.Base`) are keyed on the base's code
  too: the base runs here keeping them, and each extractor runs again
  over them, within its closure and without the emitter — a kept base
  holds the decoded facts, read back for the extractors that read them
  (`Argus.Pipeline.typed_readers/0`), and one missing from that list
  computes them again.
  """
  use ExUnit.Case,
    async: true,
    parameterize: for(part <- 0..2, do: %{part: part, parts: 3})

  alias Argus.Cache.Code

  @beams for(
           mod <- Application.spec(:panoptes, :modules),
           String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Test.Fixtures."),
           do: mod
         )
         |> Enum.sort()
         |> Enum.take_every(19)
         |> Kernel.++([
           Argus.Test.Fixtures.Specs,
           Argus.Test.Fixtures.Router,
           Argus.Test.Fixtures.Tls.ForcesNone,
           Inspect.Argus.Test.Fixtures.DerivedInspect.OneField,
           Logger.Formatter,
           :gen_server
         ])

  defp producers do
    {:ok, all} = Argus.Analysis.set(:all)

    extractors =
      Enum.flat_map(all ++ [:coverage], fn name ->
        {:ok, mod} = Argus.Analysis.fetch_module(name)
        mod.extractors()
      end)

    [:base | Enum.uniq([Argus.Extractors.CallArgs | extractors])]
  end

  # Runs in a fresh VM: call counts are VM-wide, and this one runs other
  # tests beside it.
  @measure ~S"""
  # The code, not the fixtures it reads.
  mods =
    for app <- [:panoptes, :beam_spy, :ctf],
        mod <- Application.spec(app, :modules) || [],
        not String.starts_with?(Atom.to_string(mod), ["Elixir.Argus.Test.", "Elixir.Inspect."]),
        do: mod

  Enum.each(mods, &Code.ensure_loaded/1)

  scratch = fn -> Path.join(System.tmp_dir!(), "argus_code_#{:os.getpid()}_#{System.unique_integer([:positive])}") end

  # The bases the extractors run over, kept untraced.
  dir = scratch.()
  {:ok, %{bases: bases}} = Argus.Pipeline.run_shards(beams, [{:base, dir}], keep_bases: true)
  File.rm_rf!(dir)

  run = fn producer, opts ->
    for m <- mods, do: :erlang.trace_pattern({m, :_, :_}, true, [:call_count])
    dir = scratch.()
    {:ok, _} = Argus.Pipeline.run_shards(beams, [{producer, dir}], [trace_imprecision: true] ++ opts)
    File.rm_rf!(dir)

    executed =
      for m <- mods,
          {f, a} <- m.module_info(:functions),
          f not in [:module_info, :__info__],
          match?({:call_count, n} when n > 0, :erlang.trace_info({m, f, a}, :call_count)),
          uniq: true,
          do: m

    for m <- mods, do: :erlang.trace_pattern({m, :_, :_}, false, [:call_count])
    executed
  end

  Map.new(producers, fn
    :base -> {:base, %{fresh: run.(:base, keep_bases: true), kept: []}}
    extractor -> {extractor, %{fresh: run.(extractor, []), kept: run.(extractor, bases: bases)}}
  end)
  """

  test "every module a producer executes is in its closure", %{part: part, parts: parts} do
    paths = Enum.map(@beams, &to_string(:code.which(&1)))

    producers =
      for {producer, i} <- Enum.with_index(producers()), rem(i, parts) == part, do: producer

    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

    executed =
      try do
        :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:panoptes])
        binding = [beams: paths, producers: producers]
        {executed, _} = :peer.call(peer, Elixir.Code, :eval_string, [@measure, binding], 300_000)
        executed
      after
        :peer.stop(peer)
      end

    for producer <- producers do
      {:ok, closure} = Code.closure(producer)
      closure = MapSet.new(closure, &elem(&1, 0))
      %{fresh: ran, kept: over_kept} = Map.fetch!(executed, producer)

      assert ran != [], "#{inspect(producer)} executed nothing"

      assert Enum.reject(ran ++ over_kept, &MapSet.member?(closure, &1)) == [],
             "#{inspect(producer)} runs code its key does not cover"

      refute Argus.Pipeline.Emit in over_kept,
             "#{inspect(producer)} computes the decoded facts over a kept base: " <>
               "add it to Argus.Pipeline's @typed_readers"
    end
  end
end
