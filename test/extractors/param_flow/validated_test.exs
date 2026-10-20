defmodule Argus.Extractors.ParamFlow.ValidatedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.Bounded

  @source """
  defmodule Argus.ValidatedTest.Checks do
    def role!(role) do
      unless role in ["admin", "viewer"], do: raise(ArgumentError, "unknown")
      :ok
    end

    def second!(_any, kind) when kind in ["a", "b"], do: :ok
    def second!(_any, _kind), do: raise(ArgumentError, "unknown kind")

    def answers(role), do: if(role in ["admin", "viewer"], do: :ok, else: :error)

    def raises(_role), do: raise(ArgumentError, "always")
  end
  """

  setup_all do
    [{mod, bin}] = Code.compile_string(@source)
    path = Path.join(System.tmp_dir!(), "#{mod}-#{System.unique_integer([:positive])}.beam")
    File.write!(path, bin)
    {:ok, data} = BeamSpy.BeamFile.disassemble(path)
    File.rm!(path)

    validated = fn name, arity ->
      {:function, _, _, _, instrs} =
        Enum.find(data.functions, &match?({:function, ^name, ^arity, _, _}, &1))

      Bounded.validated(Helpers.cfg(data, name, arity), instrs, arity, %{}, %{})
    end

    %{validated: validated}
  end

  test "a function that raises unless its argument is in a literal set validates it",
       %{validated: v} do
    assert %{0 => {:values, {:set, values}}} = v.(:role!, 1)
    assert Enum.sort(values) == ["admin", "viewer"]
  end

  test "only the parameter every return has checked", %{validated: v} do
    assert %{1 => {:values, {:set, ["a", "b"]}}} = v.(:second!, 2)
    refute Map.has_key?(v.(:second!, 2), 0)
  end

  test "a check that returns on both answers, or a function that never returns, validates nothing",
       %{validated: v} do
    assert v.(:answers, 1) == %{}
    assert v.(:raises, 1) == %{}
  end
end
