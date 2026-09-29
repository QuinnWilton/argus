defmodule Argus.Extractor.StateFieldsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ErrorHandling
  alias Argus.Test.Fixtures.MonitorLeak, as: M

  defp extract(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    ErrorHandling.extract(data)
  end

  defp rows(mod, relation, fragment) do
    for [func | rest] <- Map.get(extract(mod), relation, []), func =~ fragment, do: rest
  end

  describe "returned_field_from" do
    test "a removal's answer is the field it is returned in, not another field of the return" do
      # handle_cast({:rename, name}, s): `names: Map.delete(...)`, `subs: s.subs`.
      mod = M.RemovesFromAnotherField
      from = rows(mod, :returned_field_from, "handle_cast/2")

      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      {:function, _, _, _, instrs} =
        Enum.find(data.functions, &match?({:function, :handle_cast, 2, _, _}, &1))

      removal =
        Enum.find_index(instrs, &match?({:call_ext, 2, {:extfunc, :maps, :remove, 2}}, &1))

      assert for([key, site, how] <- from, site =~ "##{removal}", do: {key, how}) == [
               {":names", "whole"}
             ]
    end

    test "the element of a call's answer a field takes out" do
      from = rows(M.FoldKeepsNodesAndChecks, :returned_field_from, "handle_call/3")
      hows = for [key, _site, how] <- from, do: {key, how}
      assert {":checks", "{1}"} in hows
      assert {":nodes", "{0}"} in hows
    end

    test "a value another call's answer is made from is an argument of it" do
      # handle_info's `:DOWN` clause returns `checks: Map.delete(checks, ref)`
      # built in a call the rules do not take for the removal itself.
      hows =
        for [":checks", _site, how] <-
              rows(M.FoldKeepsNodesAndChecks, :returned_field_from, "handle_info/2"),
            do: how

      assert "whole" in hows
    end
  end

  describe "returns_from" do
    test "a helper hands back what the call it returns answered" do
      assert [[_site]] = rows(M.Monitors, :returns_from, ":add/3") |> Enum.uniq() |> Enum.take(1)
    end
  end
end
