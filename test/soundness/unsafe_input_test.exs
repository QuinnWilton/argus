defmodule Argus.Soundness.UnsafeInputTest do
  @moduledoc """
  Real bugs the precision rounds' suppressions silenced (soundness review
  2), each at the severity it had before the suppression, beside the
  shapes the suppression was for, which stay quiet
  (test/fixtures/soundness/unsafe_input_fixture.ex).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness.Case

  alias Argus.Test.Soundness.Census

  setup_all do
    unless Argus.Souffle.available?(), do: raise("souffle not installed")
    mods = modules("unsafe_input_fixture.ex")
    %{mods: mods, sev: severities(mods, [:unsafe_input])}
  end

  @atom_export "Dynamic atom creation reachable from an exported function"
  @code_export "Dynamic code execution reachable from exports"

  describe "atoms made of atoms" do
    test "an atom a lookup chose, a request's atoms and fed-back atoms stay reported", %{sev: sev} do
      # Review probes (parent: 00ffcf45 / 0df71b52's parents).
      assert severity(sev, "G2.AtomExistingPlug", :call, "Unbounded atom creation") == :error
      assert severity(sev, "G2.AtomExistingChain", :cache_key, @atom_export) == :warning
      assert severity(sev, "G2.AtomExistingChain", :scoped, @atom_export) == :warning
      assert severity(sev, "G2.AtomChain", :nested, @atom_export) == :warning

      # Adversarial neighbours: the lookup in a caller, two calls up, in
      # Erlang's spelling; a request's path; mutual recursion; folds.
      for {mod, fun} <- [
            {"Adv.Atoms.ChosenInCaller", :suffixed},
            {"Adv.Atoms.ChosenInCaller", :inner},
            {"Adv.Atoms.ChosenInCaller", :list_key},
            {"Adv.Atoms.Feedback", :ping},
            {"Adv.Atoms.Folds", :step},
            {"Adv.Atoms.Folds", :next}
          ] do
        assert severity(sev, mod, fun, @atom_export) == :warning, "#{mod}.#{fun}"
      end

      assert severity(sev, "Adv.Atoms.RoomLive", :topic, "Unbounded atom creation") == :warning
    end

    test "an atom's name one way and a caller's list the other is no bound", %{sev: sev} do
      assert severity(sev, "Adv.Atoms.Meet", :name, @atom_export) == :warning
      assert severity(sev, "Adv.Atoms.Meet", :decode, "binary_to_term") == :error
    end

    test "counts multiply and literals join as a set", %{sev: sev} do
      for fun <- [:tile, :voxel],
          do: assert(severity(sev, "G2.RangeProduct", fun, @atom_export) == :warning)

      for fun <- [:cell, :grid, :band, :slot],
          do: assert(severity(sev, "Adv.Atoms.Products", fun, @atom_export) == :warning)
    end

    test "what the bound is for stays quiet", %{sev: sev} do
      for {mod, fun} <- [
            {"Adv.Atoms.Quiet", :small},
            {"Adv.Atoms.Quiet", :pooled},
            {"Adv.Atoms.Quiet", :sup_name},
            {"Adv.Atoms.Quiet", :arms},
            {"Adv.Atoms.FoldQuiet", :tag}
          ] do
        assert severity(sev, mod, fun, "atom") == nil, "#{mod}.#{fun}"
      end
    end
  end

  describe "cookies" do
    test "an unverified cookie after a signed fetch is request data", %{sev: sev} do
      assert severity(sev, "G1.Prefs", :decode, "binary_to_term") == :error
      assert severity(sev, "G1.CookieController", :prefs, "binary_to_term") == :error
      assert severity(sev, "G1.CookieController", :theme, "atom") == :error
    end

    test "only the verified names read off the returned conn are the server's", %{mods: mods} do
      entries =
        for [_, "Argus.Test.Soundness.Adv.Cookies.Codec:decode/1", _, _, entry, _, "flow" | _] <-
              rows(mods, :unsafe_input, "sink_reachable"),
            do: entry |> String.split(":") |> List.last()

      assert Enum.sort(entries) ==
               ["chosen/2", "raw/2", "stale/2", "via_get/2", "via_match/2"]
    end
  end

  describe "templates" do
    test "a render naming its template carries the request's params", %{sev: sev} do
      assert severity(sev, "G8.CalcView", :"result.json", "code execution") == :error
      assert severity(sev, "G8.ScopesView", :"-_scopes.html/1-fun-0-", "atom") == :error
    end

    test "through a dispatch only to the template the name picks", %{mods: mods} do
      flows =
        for [_, func, _, _, entry, _, "flow" | _] <- rows(mods, :unsafe_input, "sink_reachable"),
            String.contains?(func, "Adv.Tpl.View"),
            do:
              {func |> String.split(":") |> List.last(),
               entry |> String.split(":") |> List.last()}

      assert Enum.sort(flows) == [
               {"-tags.html/1-fun-0-/1", "tags/2"},
               {"run.json/1", "direct/2"},
               {"run.json/1", "run/2"}
             ]
    end
  end

  describe "task streams" do
    test "a stream a request does not enumerate itself is unbounded", %{mods: mods, sev: sev} do
      assert severity(sev, "G1.BackgroundStreamLive", :fan_out, "without limit") == :error

      vias =
        for [_, _, via, _] <- rows(mods, :unsafe_input, "unbounded_children_from_request"),
            String.contains?(via, "Adv.Stream"),
            do: via |> String.split(".") |> List.last()

      assert Enum.sort(vias) ==
               [
                 "Controller:fan_b/1",
                 "Controller:sync/2",
                 "Live:fan_a/1",
                 "Live:fan_c/1",
                 "Live:handle_event/3"
               ]
    end
  end

  describe "programs PATH finds" do
    test "wrappers and interpreters run their arguments", %{sev: sev} do
      for fun <- [:via_env, :via_ssh, :via_docker, :via_search_path],
          do: assert(severity(sev, "G9.FoundWrapper", fun, @code_export) == :error)

      for fun <- [:run_snippet, :php],
          do: assert(severity(sev, "G9.FoundMix", fun, @code_export) == :error)

      for fun <- [:via_sudo, :via_xargs, :via_timeout, :via_lua, :via_awk, :literal_env, :search],
          do: assert(severity(sev, "Adv.Found.Wrappers", fun, @code_export) == :error)
    end

    test "a program that runs none of its arguments stays quiet", %{sev: sev} do
      assert severity(sev, "Adv.Found.Quiet", :dims, "code") == nil
      assert severity(sev, "Adv.Found.Quiet", :literal, "code") == nil
    end
  end

  test "an export named like reflection that takes data is a way in", %{sev: sev} do
    assert severity(sev, "Adv.Dunder", :__eval__, @code_export) == :error
  end

  test "a socket's bytes in a server's handle_info are an outside party's", %{sev: sev} do
    assert severity(sev, "G6.RanchAtom", :handle_info, @atom_export) == :warning
  end

  # The exclusion census's unsafe_input holes (docs/design/exclusions.md),
  # over one fixture set (test/fixtures/soundness/unsafe_input_census.ex
  # and the census_* modules of test/fixtures/erl).
  @census [
    Census.UnsafeInput.Key,
    Census.UnsafeInput.Key.BitString,
    Census.UnsafeInput.Key.Atom,
    Census.UnsafeInput.Named,
    Census.UnsafeInput.Label,
    Census.UnsafeInput.Label.Argus.Test.Soundness.Census.UnsafeInput.Named,
    String.Chars.Argus.Test.Soundness.Census.UnsafeInput.Named,
    :census_tree_names,
    :census_tree_levels,
    :census_flat_names
  ]

  defp census do
    {:ok, res} = Argus.Test.Memo.run_analyses(@census, analyses: [:unsafe_input])
    MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})
  end

  defp census_quiet?(mod), do: not Enum.any?(census(), &match?({_, _, {^mod, _, _}}, &1))

  # census: protocol-relay
  # A protocol's implementation was never a way in.
  describe "census hole: the implementation of the program's own protocol" do
    for mfa <- [
          {Census.UnsafeInput.Key.BitString, :to_key, 1},
          {Census.UnsafeInput.Label.Argus.Test.Soundness.Census.UnsafeInput.Named, :label, 2}
        ] do
      test "#{inspect(mfa)} makes an atom of what its protocol's caller hands it" do
        assert {:warning, @atom_export, unquote(Macro.escape(mfa))} in census()
      end
    end

    test "an implementation of a protocol the program does not define is quiet" do
      assert census_quiet?(String.Chars.Argus.Test.Soundness.Census.UnsafeInput.Named)
    end
  end

  # census: comprehension-feedback
  # An Erlang comprehension's function was never on a cycle.
  describe "census hole: a comprehension that feeds its atom back" do
    for mod <- [:census_tree_names, :census_tree_levels] do
      test "#{inspect(mod)}: each level's atom is the next level's parent" do
        assert {:warning, @atom_export, {unquote(mod), :"-names/2-lc$^0/1-0-", 2}} in census()
      end
    end

    test "a comprehension whose atoms do not come back is quiet" do
      assert census_quiet?(:census_flat_names)
    end
  end
end
