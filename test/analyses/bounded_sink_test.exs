defmodule Argus.Analyses.BoundedSinkTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Fixtures.BoundedConversion
  alias Argus.Test.Fixtures.BoundedMapKey
  alias Argus.Test.Memo

  setup_all do
    {:ok, result} = Memo.analyze([BoundedConversion, BoundedMapKey], :unsafe_input)
    %{rows: result["sink_without_request_path"] ++ result["sink_reachable"]}
  end

  defp reported?(rows, module, name) do
    func = inspect(module) <> ":" <> name
    Enum.any?(rows, fn [_, f | _] -> f == func end)
  end

  describe "pure calls on bounded values" do
    test "keep the bound through string, atom-name and element calls", %{rows: rows} do
      for name <- ["codec_name/1", "unescape_atom/1", "segment/1"] do
        refute reported?(rows, BoundedConversion, name), name
      end
    end

    test "do not bound an open input, or a function argument's results", %{rows: rows} do
      for name <- [
            "open_codec_name/1",
            "unescape_binary/1",
            "open_segment/1",
            "mapped/1",
            "replaced/2"
          ] do
        assert reported?(rows, BoundedConversion, name), name
      end
    end
  end

  describe "a key found in a literal map" do
    test "is one of its keys on the edge where it was found", %{rows: rows} do
      for name <- [
            "fetched/2",
            "fetched_with/1",
            "fetched!/1",
            "has_key/1",
            "guarded/1",
            "either_map/2"
          ] do
        refute reported?(rows, BoundedMapKey, name), name
      end
    end

    test "is not bounded where it was not found, or in a caller's map", %{rows: rows} do
      for name <- ["fetched_error_arm/2", "has_no_key/1", "caller_map/2", "caller_fetch/2"] do
        assert reported?(rows, BoundedMapKey, name), name
      end
    end

    test "is_map_key/2 as a value is a pending membership of the key in x1" do
      alias Argus.Extractors.ParamFlow.Bounded

      state = %{
        bounded: %{},
        binaries: MapSet.new(),
        lists: %{},
        groups: [],
        pending: %{},
        ranges: %{},
        returns: %{}
      }

      instr = {:bif, :is_map_key, {:f, 0}, [{:x, 1}, {:literal, %{"b" => 1, "a" => 2}}], {:x, 2}}

      assert Bounded.step(instr, state).pending == %{
               {:x, 2} => {[{:x, 1}], {:values, {:set, ["a", "b"]}}}
             }

      # A fetch is settled where it found the key, not where it is truthy.
      call = {:call_ext, 2, {:extfunc, :maps, :find, 2}}

      state = %{
        state
        | bounded: %{{:x, 1} => {:values, {:set, [%{"a" => 1}]}}},
          groups: [[{:x, 0}, {:y, 0}]]
      }

      assert Bounded.step(call, state).pending == %{
               {:x, 0} => {[{:y, 0}], {:found, {:values, {:set, ["a"]}}}}
             }
    end
  end
end
