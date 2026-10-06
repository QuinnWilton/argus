defmodule Argus.Pipeline.DeterminismTest do
  @moduledoc """
  The same beams yield byte-identical facts in any VM. A VM iterates a
  small map (or set) whose keys hold atoms in atom-table order, which
  depends on which atoms that VM happened to create first; a fact that
  spells a literal map, or a relation built by iterating such a set,
  would otherwise differ between two runs over the same code — and every
  cache keyed on the facts would miss.
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  # Created in the reverse of their sorted order, so this VM iterates a
  # map holding them b-first.
  defp reversed_atoms(tag) do
    suffix = System.unique_integer([:positive])
    b = String.to_atom("det_#{tag}_b_#{suffix}")
    a = String.to_atom("det_#{tag}_a_#{suffix}")
    {a, b}
  end

  test "a literal map is spelled with its keys sorted, however the VM orders them" do
    {a, b} = reversed_atoms("map")
    {c, d} = reversed_atoms("set")
    assert Map.keys(%{a => 1, b => 2}) == [b, a], "precondition: this VM orders b first"

    mod = :"Elixir.Argus.DeterminismProbe#{System.unique_integer([:positive])}"

    [{^mod, bin}] =
      Code.compile_string("""
      defmodule #{inspect(mod)} do
        def map, do: %{#{a}: 1, #{b}: 2}
        def nested, do: [{:ok, %{#{b}: %{#{a}: 1, #{b}: 2}, #{a}: 0}}]
        def set, do: #{inspect(MapSet.new([c, d]))}
      end
      """)

    {:ok, facts} = Pipeline.extract([bin])
    spelled = MapSet.new(facts.literal_value, fn [_id, _reg, value] -> value end)

    assert "%{#{a}: 1, #{b}: 2}" in spelled
    assert "[ok: %{#{a}: 0, #{b}: %{#{a}: 1, #{b}: 2}}]" in spelled
    assert "%{__struct__: MapSet, map: %{#{c}: [], #{d}: []}}" in spelled
  end

  @beams [
    Argus.Test.Fixtures.ConditionalInitServer,
    Argus.Test.Fixtures.Quiet,
    Inspect.Opts,
    Calendar.ISO,
    Logger.Formatter,
    URI
  ]

  # Two fresh VMs, each loading the pipeline and extracting with every
  # extractor: under a second on a fast machine, and minutes on a runner
  # whose cores the rest of the suite holds.
  @tag timeout: 300_000
  test "two VMs whose atom tables were seeded in opposite orders extract the same facts" do
    paths = Enum.map(@beams, &to_string(:code.which(&1)))

    atoms =
      paths
      |> Enum.flat_map(fn path ->
        {:ok, {_, [atoms: atoms]}} = :beam_lib.chunks(String.to_charlist(path), [:atoms])
        Enum.map(atoms, fn {_n, atom} -> Atom.to_string(atom) end)
      end)
      |> Enum.uniq()

    extractors =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.flat_map(& &1.extractors())
      |> Enum.uniq()

    [forward, backward] =
      [atoms, Enum.reverse(atoms)]
      |> Enum.map(&Task.async(fn -> extract_in_peer(paths, &1, extractors) end))
      |> Task.await_many(:infinity)

    assert Map.keys(forward) == Map.keys(backward)

    for {relation, rows} <- forward do
      assert rows == Map.fetch!(backward, relation), "#{relation} differs between the VMs"
    end
  end

  # A fresh VM that creates `atoms` in the given order before it loads a
  # single module of the pipeline, so the atoms of every literal it reads
  # sit in its atom table in that order.
  #
  # A bare `:peer`, not `Argus.Test.Peer`: that one's boot starts Logger,
  # Mix and ExUnit, which loads four of `@beams` (Inspect.Opts and the
  # others from Elixir) and creates their atoms in the same order in both
  # VMs before this seeds them. Over Inspect.Opts alone, it passes with
  # `sort_maps` taken out of `Argus.Extractor.Terms.spell/1`.
  defp extract_in_peer(paths, atoms, extractors) do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

    try do
      :ok = call(peer, :code, :add_pathsa, [:code.get_path()])
      :ok = call(peer, :lists, :foreach, [&String.to_atom/1, atoms])
      {:ok, _} = call(peer, :application, :ensure_all_started, [:argus_beam])
      {:ok, facts} = call(peer, Pipeline, :extract, [paths, [extractors: extractors]])
      facts
    after
      :peer.stop(peer)
    end
  end

  # Bounded by the test's timeout, not the call's: `:peer.call/4`'s five
  # seconds is less than starting argus's applications took in a peer on
  # a CI runner the corpus was compiling on, though the start does no
  # work of argus's own (it has no application callback).
  defp call(peer, module, function, args),
    do: :peer.call(peer, module, function, args, :infinity)
end
