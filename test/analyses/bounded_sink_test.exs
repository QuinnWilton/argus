defmodule Argus.Analyses.BoundedSinkTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Fixtures.BoundedConversion
  alias Argus.Test.Memo

  setup_all do
    {:ok, result} = Memo.analyze([BoundedConversion], :unsafe_input)
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
end
