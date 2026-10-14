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
            def closure(args), do: apply(fn y -> send(y, :hi) end, args)
            def external(args), do: apply(&File.read/1, args)
          end
          """)
        end)

      {:ok, facts} = Pipeline.extract([beam], extractors: [Argus.Extractors.Purity])

      targets =
        Map.new(Map.get(facts, :resolved_apply, []), fn [_id, caller, target] ->
          {caller, target}
        end)

      impure = for [_id, caller, api, _cat, _mode] <- facts[:impure_call], do: {caller, api}

      %{targets: targets, impure: impure}
    end

    test "apply/2 of a closure or an external fun names what it runs", %{targets: targets} do
      mod = "Argus.Extractors.PurityTest.Applies"
      assert targets["#{mod}:closure/1"] == "#{mod}:-closure/1-fun-0-/1"
      assert targets["#{mod}:external/1"] == "File:read/1"
    end

    test "a resolved apply's effect is its target's", %{impure: impure} do
      assert {"Argus.Extractors.PurityTest.Applies:external/1", "File.read/1"} in impure
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

  describe "effects that compile to a bif instruction" do
    # `self/0`, `node/0` and `:erlang.get/1` compile to `bif`, not a call,
    # so the remote-call scan never sees them. The quiet half are guard
    # BIFs that compute from their arguments alone, `node/1` among them.
    setup do
      {[{_, beam}], _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Argus.Extractors.PurityTest.Bifs do
            def me, do: self()
            def here, do: node()
            def cached(key), do: :erlang.get(key)
            def owner_node(pid) when is_pid(pid), do: node(pid)
            def head_size(tuple, list), do: {tuple_size(tuple), elem(tuple, 0), hd(list), length(list)}
          end
          """)
        end)

      {:ok, facts} = Pipeline.extract([beam], extractors: [Argus.Extractors.Purity])

      rows =
        for [_id, "Argus.Extractors.PurityTest.Bifs:" <> func, api, category, mode] <-
              Map.get(facts, :impure_call, []),
            do: {func, api, category, mode}

      %{rows: rows}
    end

    test "are classified as the :erlang calls they are", %{rows: rows} do
      assert {"me/0", ":erlang.self/0", "process", "read"} in rows
      assert {"here/0", ":erlang.node/0", "node", "read"} in rows
      assert {"cached/1", ":erlang.get/1", "process_dict", "read"} in rows
    end

    test "a guard bif computing from its arguments is not one", %{rows: rows} do
      refute Enum.any?(rows, &match?({"owner_node/1", _, _, _}, &1)), inspect(rows)
      refute Enum.any?(rows, &match?({"head_size/2", _, _, _}, &1)), inspect(rows)
    end
  end
end
