defmodule Argus.Analyses.ApiSurfaceTest do
  @moduledoc """
  Which exports unsafe_input counts as a way in for a caller's data
  (`outside_api`): the documented ones, a hidden one only when the
  program itself does not call it, and a `__name__` hook only when its
  calls run where a macro expands.
  """

  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Fixtures.ApiSurface
  alias Argus.Test.Memo

  setup_all do
    {:ok, result} =
      Memo.analyze(
        [ApiSurface, ApiSurface.Grammar, ApiSurface.Plug, ApiSurface.Router],
        :unsafe_input
      )

    %{exposed: result["sink_without_request_path"], reached: result["sink_reachable"]}
  end

  defp reported?(rows, func),
    do: Enum.any?(rows, fn [_, f | _] -> f == func end)

  describe "a function the docs hide" do
    test "the library calls only with its own grammar makes no caller's atoms", %{exposed: rows} do
      refute reported?(rows, "#{inspect(ApiSurface.Grammar)}:keyword/1")
    end

    test "the library calls with an empty schema makes no caller's atoms", %{exposed: rows} do
      refute reported?(rows, "#{inspect(ApiSurface)}:-columns/1-fun-0-/1")
    end

    test "a documented function hands the caller's input stays reported", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Grammar)}:word/1")
    end

    test "nothing in the program calls stays a way in", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Grammar)}:orphan/1")
    end

    test "a request handler hands the request's data stays reported", %{reached: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Grammar)}:param/1")
    end

    test "a function a quote defines calls stays reported", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Grammar)}:event/1")
    end
  end

  describe "a function a quote calls" do
    test "a hook only a macro's expansion calls makes no caller's atoms", %{exposed: rows} do
      refute reported?(rows, "#{inspect(ApiSurface.Router)}:__sessions__/2")
    end

    test "a hook a function the quote defines calls stays reported", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Router)}:__handle__/1")
    end

    test "a hook the program's runtime also calls stays reported", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Router)}:__register__/1")
    end

    test "a documented function that is no hook stays reported", %{exposed: rows} do
      assert reported?(rows, "#{inspect(ApiSurface.Router)}:name_atom/1")
    end
  end

  test "a documented function taking the caller's input stays reported", %{exposed: rows} do
    assert reported?(rows, "#{inspect(ApiSurface)}:documented/1")
  end
end
