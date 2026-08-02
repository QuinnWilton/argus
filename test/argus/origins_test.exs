defmodule Argus.OriginsTest do
  use ExUnit.Case, async: true

  alias Argus.Origins

  defp beam(mod), do: to_string(:code.which(mod))

  describe "classify/1" do
    test "separates a fixture from the library that analyses it" do
      origins = Origins.classify([beam(Argus.Origins), beam(Argus.Test.Fixtures.MyGenServer)])

      assert origins["Argus.Origins"] == :lib

      assert origins["Argus.Test.Fixtures.MyGenServer"] == :test,
             "fixtures exist to make analyses fire, and reporting them is noise"
    end

    test "a module with no compile info is unknown, not guessed" do
      # Stripped beams happen. Absence of provenance is not evidence about
      # provenance, and calling it :lib would quietly promote scaffolding.
      assert Origins.classify(["/nonexistent/Elixir.Ghost.beam"]) == %{"Ghost" => :unknown}
    end
  end

  describe "reject/4" do
    test "drops rows by their module column" do
      origins = %{"A" => :test, "B" => :lib, "C" => :dep}
      rows = [["A", "x"], ["B", "y"], ["C", "z"]]

      assert Origins.reject(rows, origins, [:test]) == [["B", "y"], ["C", "z"]]

      assert Origins.reject(rows, origins, [:test, :dep]) == [["B", "y"]]
    end

    test "keeps rows whose origin is unknown" do
      # Dropping on absent evidence would hide findings rather than noise.
      assert Origins.reject([["Z", "x"]], %{}, [:test]) == [["Z", "x"]]
    end
  end
end
