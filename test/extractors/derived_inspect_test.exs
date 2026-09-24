defmodule Argus.Extractors.DerivedInspectTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.DerivedInspect
  alias Argus.Test.Fixtures.Secret, as: S

  defp extract(mod) do
    {:beam_file, ^mod, _exports, _attrs, _compile, functions} =
      :beam_disasm.file(:code.which(mod))

    DerivedInspect.extract(%{module: mod, functions: functions})
  end

  defp shows(facts), do: facts |> Map.get(:inspect_shows, []) |> Enum.sort()

  test "except: shows every field it does not list" do
    facts = extract(Inspect.Argus.Test.Fixtures.Secret.DerivedExcept)
    mod = inspect(S.DerivedExcept)

    assert facts.inspect_derived == [[mod]]
    assert shows(facts) == [[mod, ":host"], [mod, ":id"], [mod, ":sendgrid_api_key"]]
  end

  test "only: shows what it lists" do
    facts = extract(Inspect.Argus.Test.Fixtures.Secret.DerivedOnly)
    mod = inspect(S.DerivedOnly)
    assert shows(facts) == [[mod, ":id"], [mod, ":name"]]
  end

  test "a plain derive shows every field" do
    facts = extract(Inspect.Argus.Test.Fixtures.Secret.RedactOverridden)
    mod = inspect(S.RedactOverridden)
    assert shows(facts) == [[mod, ":id"], [mod, ":password"]]
  end

  test "only: [] shows nothing, and is still a derived Inspect" do
    facts = extract(Inspect.Argus.Test.Fixtures.DerivedInspect.ShowsNothing)
    assert facts.inspect_derived == [[inspect(Argus.Test.Fixtures.DerivedInspect.ShowsNothing)]]
    assert shows(facts) == []
  end

  test "one field is an is_eq_exact rather than a select_val" do
    facts = extract(Inspect.Argus.Test.Fixtures.DerivedInspect.OneField)
    assert shows(facts) == [[inspect(Argus.Test.Fixtures.DerivedInspect.OneField), ":id"]]
  end

  test "optional: compares no further atoms with the field" do
    facts = extract(Inspect.Argus.Test.Fixtures.DerivedInspect.Optional)
    mod = inspect(Argus.Test.Fixtures.DerivedInspect.Optional)
    assert shows(facts) == [[mod, ":id"], [mod, ":name"]]
  end

  test "a hand-written Inspect is not a derived one" do
    assert extract(Inspect.Argus.Test.Fixtures.DerivedInspect.HandWritten) == %{}
  end

  test "a module that is no Inspect impl yields nothing" do
    assert extract(S.DerivedExcept) == %{}
  end
end
