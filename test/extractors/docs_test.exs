defmodule Argus.Extractors.DocsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Docs
  alias Argus.Test.Fixtures.ApiSurface

  defp hidden(input) do
    {:ok, facts} = Argus.Pipeline.extract([input], extractors: [Docs])
    facts |> Map.get(:doc_hidden, []) |> Enum.map(fn [func] -> func end) |> Enum.sort()
  end

  test "a @doc false function of a documented module, at each arity its defaults make" do
    assert hidden(ApiSurface) ==
             ["#{inspect(ApiSurface)}:describe/1", "#{inspect(ApiSurface)}:describe/2"]
  end

  test "every function of a @moduledoc false module, and no function the compiler adds" do
    expected =
      for fun <- ~w(keyword/1 keywords/1 orphan/1 param/1 rules/0 rules/1 word/1),
          do: "#{inspect(ApiSurface.Grammar)}:#{fun}"

    assert hidden(ApiSurface.Grammar) == expected
  end

  test "@impl true hides a callback" do
    assert hidden(ApiSurface.Plug) ==
             ["#{inspect(ApiSurface.Plug)}:call/2", "#{inspect(ApiSurface.Plug)}:init/1"]
  end

  test "a beam without a Docs chunk hides nothing" do
    forms =
      for source <- [~c"-module(argus_docs_test_plain).", ~c"-export([f/1]).", ~c"f(X) -> X."] do
        {:ok, tokens, _} = :erl_scan.string(source)
        {:ok, form} = :erl_parse.parse_form(tokens)
        form
      end

    {:ok, _mod, bin} = :compile.forms(forms, [:binary])
    assert hidden(bin) == []
  end
end
