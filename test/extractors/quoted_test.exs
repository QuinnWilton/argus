defmodule Argus.Extractors.QuotedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Quoted
  alias Argus.Test.Fixtures.ApiSurface.Router

  @router inspect(Router)

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Router], extractors: [Quoted])
    %{rows: Map.get(facts, :quoted_call, [])}
  end

  defp calls(rows, callee),
    do: for([func, _mod, ^callee, arity, context] <- rows, do: {func, arity, context})

  test "a call at the top of a macro's bind_quoted return runs where it expands", %{rows: rows} do
    assert calls(rows, "__sessions__") == [{"#{@router}:MACRO-mount/3", "2", "expansion"}]
  end

  test "a call inside a function the quote defines runs in that function", %{rows: rows} do
    assert calls(rows, "__handle__") == [{"#{@router}:MACRO-handler/1", "1", "function"}]
  end

  test "an alias names the module the quote expanded it to", %{rows: rows} do
    assert [[_, mod, "event", "1", "function"]] =
             Enum.filter(rows, &match?([_, _, "event" | _], &1))

    assert mod == inspect(Argus.Test.Fixtures.ApiSurface.Grammar)
  end

  test "a call on `__MODULE__` names no module, and an unquoted argument no arity" do
    shapes = inspect(Argus.Test.Fixtures.ApiSurface.QuoteShapes)

    {:ok, facts} =
      Argus.Pipeline.extract([Argus.Test.Fixtures.ApiSurface.QuoteShapes], extractors: [Quoted])

    assert Map.get(facts, :quoted_call, []) == [
             ["#{shapes}:MACRO-in_fn/2", shapes, "__hook__", "-1", "function"]
           ]
  end
end
