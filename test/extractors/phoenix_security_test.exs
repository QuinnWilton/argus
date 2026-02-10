defmodule Argus.Extractors.PhoenixSecurityTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.PhoenixSecurity

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — raw SQL" do
    test "detects Ecto.Adapters.SQL.query call" do
      facts = PhoenixSecurity.extract(disassemble(Argus.Test.Fixtures.RawSqlModule))

      assert Map.has_key?(facts, :raw_sql_call)
      rows = facts[:raw_sql_call]
      assert length(rows) >= 1

      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "Ecto.Adapters.SQL"))
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = PhoenixSecurity.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Extract.extract/2" do
      assert {:ok, facts} =
               Argus.Extract.extract(
                 [Argus.Test.Fixtures.RawSqlModule],
                 extractors: [PhoenixSecurity]
               )

      assert Map.has_key?(facts, :raw_sql_call)
    end
  end
end
