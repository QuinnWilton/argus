defmodule Argus.Extractors.PurityTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  describe "resolved_apply" do
    setup do
      # The compiler turns an apply of a list it can see whole into a
      # direct call, so only the lists it cannot are left to resolve. It
      # warns about the improper one, which is the point.
      {[{_, beam}], _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Argus.Extractors.PurityTest.Applies do
            def open_tail(x, rest), do: apply(Enum, :zip, [x | rest])
            def improper, do: apply(Enum, :zip, [:a | :b])
          end
          """)
        end)

      {:ok, facts} = Pipeline.extract([beam], extractors: [Argus.Extractors.Purity])

      targets =
        Map.new(Map.get(facts, :resolved_apply, []), fn [_id, caller, target] ->
          {caller, target}
        end)

      %{targets: targets}
    end

    # `[x | rest]` used to resolve as the two-element list `[x, :dynamic]`,
    # naming Enum.zip/2 whatever `rest` held.
    test "an argument list with an unknown tail names no arity", %{targets: targets} do
      refute Map.has_key?(targets, "Argus.Extractors.PurityTest.Applies:open_tail/2")
    end

    test "an improper argument list names no arity", %{targets: targets} do
      refute Map.has_key?(targets, "Argus.Extractors.PurityTest.Applies:improper/0")
    end
  end
end
