defmodule Argus.Extractors.EctoSchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractors.EctoSchema
  alias Argus.Test.Fixtures.Secret, as: S

  defp extract(mod) do
    {:beam_file, ^mod, _exports, _attrs, _compile, functions} =
      :beam_disasm.file(:code.which(mod))

    EctoSchema.extract(%{module: mod, functions: functions})
  end

  defp types(mod) do
    mod
    |> extract()
    |> Map.fetch!(:schema_field)
    |> Map.new(fn [_mod, field, type] -> {field, type} end)
  end

  test "every persisted field carries its type from __schema__/2" do
    assert types(S.Heuristic) == %{
             ":id" => "id",
             ":totp_seed" => "Argus.Test.Encrypted.Binary",
             ":label" => "string"
           }
  end

  test "each shape of type is spelled for a reader" do
    assert types(S.Typed) == %{
             ":id" => "binary_id",
             ":body" => "MyApp.Markdown",
             ":profile" => "embeds_one MyApp.Profile",
             ":history" => "embeds_many MyApp.Change",
             ":status" => "Ecto.Enum",
             ":tags" => "array of string",
             ":scores" => "map of integer",
             # A shape no reader could name, and a field __schema__/2
             # has no clause for: neither is guessed.
             ":opaque" => "dynamic",
             ":untyped" => "dynamic"
           }
  end

  test "a schema without __schema__/2 has fields of type dynamic" do
    assert types(S.Exposed) |> Map.values() |> Enum.uniq() == ["dynamic"]
  end

  test "the redacted fields keep their two columns" do
    assert extract(S.PartlyRedacted).redacted_field == [[inspect(S.PartlyRedacted), ":api_key"]]
  end

  property "any term spells as a string" do
    check all(term <- term()) do
      assert is_binary(EctoSchema.type_name(term))
      assert is_binary(EctoSchema.type_name({:array, term}))
      assert is_binary(EctoSchema.type_name({:parameterized, {Ecto.Embedded, term}}))
    end
  end
end
