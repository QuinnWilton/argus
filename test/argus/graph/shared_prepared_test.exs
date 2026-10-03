defmodule Argus.Graph.SharedPreparedTest do
  use ExUnit.Case, async: true

  alias Argus.Graph.Prepared
  alias Argus.Instr.Reaching
  alias Argus.Pipeline
  alias Argus.Pipeline.{Base, Disassemble}
  alias Argus.Schema.Reads
  alias Roux.{Blob, Database}

  test "cold preparation preserves facts and reads without retaining the spec memo" do
    data = fixture()
    opts = [producers: [:base], keep_base: true, trace_imprecision: true]
    expected = Reads.track(fn -> Pipeline.extract_data(data, opts) end)

    {{{:ok, actual}, captured}, reads} =
      Reads.track(fn ->
        Prepared.capture(fn callback ->
          Pipeline.extract_data(data, Keyword.put(opts, :on_prepared, callback))
        end)
      end)

    assert {{:ok, actual}, reads} == expected
    refute Map.has_key?(actual, :prepared)

    with_db(fn db ->
      base = fingerprint(actual)
      Prepared.remember(db, data.module, :function, base, captured)

      live =
        Prepared.fetch(db, data.module, :function, base.fingerprint, fn ->
          flunk("a newly prepared base must be reused without restoration")
        end)

      refute Map.has_key?(live, :installed_specs)
      restored = Base.restore(base.base, "")
      assert live.typed == elem(restored.typed, 1)
      assert live.cfg == restored.cfg
      assert live.reaching == restored.reaching
      assert :erlang.binary_to_term(:erlang.term_to_binary(live)) == live
    end)
  end

  test "module assembly reuses the function bases and indexes" do
    data = fixture()

    with_db(fn db ->
      parts =
        for function <- data.functions do
          key = {elem(function, 1), elem(function, 2)}
          {base, captured} = captured_base(%{data | functions: [function]})
          Prepared.remember(db, data.module, key, base, captured)
          Prepared.function(db, data.module, key, base)
        end

      assembled = Prepared.assemble(Map.drop(data, [:functions, :line_table]), parts)

      rebuilt =
        assembled
        |> Map.drop([:call_sites, :origins_index])
        |> Pipeline.prepare_indexes()

      assert assembled == rebuilt

      producers = [Argus.Extractors.ETS, Argus.Extractors.TermFlow]
      opts = [producers: producers, trace_imprecision: true]
      {:ok, expected} = Pipeline.extract_data(data, opts)
      {:ok, actual} = Pipeline.extract_prepared(assembled, opts)
      assert actual.facts == expected.facts
      assert actual.installed == expected.installed
    end)
  end

  test "a remembered base reinstalls its solutions after another module replaces them" do
    data = fixture()
    {base, captured} = captured_base(data)

    with_db(fn db ->
      Prepared.remember(db, data.module, :function, base, captured)
      live = Prepared.function(db, data.module, :function, base)

      other = [
        {:func_info, {:atom, OtherPreparedModule}, {:atom, :run}, 0},
        {:move, {:atom, :different}, {:x, 0}},
        :return
      ]

      assert Reaching.sources(other, 2, {:x, 0}) == [1]

      assert Prepared.function(db, data.module, :function, base) == live
      assert Reaching.uses(data.module, data.functions) == live.reaching
    end)
  end

  test "live state does not outlive its fingerprint, database, module, or code version" do
    data = fixture()
    {base, captured} = captured_base(data)

    with_db(fn db ->
      with_db(fn other_db ->
        scopes = [
          {db, data.module, {:prepared, "changed"}},
          {other_db, data.module, base.fingerprint},
          {db, OtherPreparedModule, base.fingerprint}
        ]

        for {next_db, next_module, identity} <- scopes do
          Prepared.remember(db, data.module, :function, base, captured)

          assert catch_throw(
                   Prepared.fetch(next_db, next_module, :function, identity, fn ->
                     throw(:prepare_again)
                   end)
                 ) == :prepare_again
        end

        Prepared.remember(db, data.module, :function, base, captured)
        Database.register_query(db, :extraction_local, %{code_version: "changed"})

        assert catch_throw(
                 Prepared.fetch(db, data.module, :function, base.fingerprint, fn ->
                   throw(:prepare_again)
                 end)
               ) == :prepare_again
      end)
    end)
  end

  test "failed and mismatched preparation cannot seed a live base" do
    data = fixture()
    {base, captured} = captured_base(data)

    with_db(fn db ->
      for unavailable <- [nil, {"different kept binary", elem(captured, 1)}] do
        Prepared.remember(db, data.module, :function, base, unavailable)

        assert catch_throw(
                 Prepared.fetch(db, data.module, :function, base.fingerprint, fn ->
                   throw(:prepare_again)
                 end)
               ) == :prepare_again
      end
    end)

    {{:ok, failed}, nil} =
      Prepared.capture(fn callback ->
        Pipeline.extract_data(%{data | functions: [:malformed_function]},
          producers: [:base],
          keep_base: true,
          on_prepared: callback
        )
      end)

    assert failed.base == nil
    assert failed.facts.base.extraction_error != ""
  end

  test "a missing reaching solution remains missing during module assembly" do
    data = fixture()
    {base, captured} = captured_base(data)

    with_db(fn db ->
      Prepared.remember(db, data.module, :function, base, captured)
      part = Prepared.function(db, data.module, :function, base)
      missing = %{part | reaching: nil, typed: nil, cfg: %{}, origins_index: %{}}
      assembled = Prepared.assemble(%{module: data.module}, [part, missing])
      assert assembled.reaching == nil
      assert assembled.origins_index == %{}
      assert assembled.typed == part.typed
    end)
  end

  test "capture scopes do not leak on exceptions or overwrite enclosing captures" do
    data = %{module: EmptyPreparedModule, functions: [], reaching: nil}
    keys = MapSet.new(Process.get_keys())

    assert_raise RuntimeError, "stop", fn ->
      Prepared.capture(fn callback ->
        callback.("abandoned", data)
        raise "stop"
      end)
    end

    assert MapSet.new(Process.get_keys()) == keys

    {:done, {"outer", _prepared}} =
      Prepared.capture(fn callback ->
        callback.("outer", data)

        assert {:ok, {"inner", _prepared}} =
                 Prepared.capture(fn callback -> callback.("inner", data) end)

        :done
      end)

    assert MapSet.new(Process.get_keys()) == keys
  end

  defp captured_base(data) do
    {{:ok, base}, captured} =
      Prepared.capture(fn callback ->
        Pipeline.extract_data(data,
          producers: [:base],
          keep_base: true,
          on_prepared: callback
        )
      end)

    {fingerprint(base), captured}
  end

  defp fingerprint(base), do: Map.put(base, :fingerprint, {:prepared, Blob.digest(base.base)})

  defp fixture do
    module = Argus.Test.Fixtures.ParamFlow.Shapes
    {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(module)))
    data
  end

  defp with_db(run) do
    db = Database.new()

    try do
      run.(db)
    after
      Database.shutdown(db)
    end
  end
end
