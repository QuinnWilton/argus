defmodule Argus.Graph.Identity.SchemaReadsTest do
  @moduledoc """
  A query is keyed on the schema entries it read, not on the schema's
  code (`schema_entry`, `Argus.Graph.Reads`), and a producer's rows are
  kept the same way (`Argus.Graph.Pack`). That holds only while nothing hands out schema data
  without recording the read. This calls every export of `Argus.Schema`
  and of every module under it, with every valid argument, and fails
  unless each call records a read whose value (`Argus.Schema.reread/1`)
  is exactly what it returned — so an accessor added without recording,
  or recording less than it returns, fails here.

  An export that takes arguments is called with the ones `arguments/3`
  lists; one it does not know fails the test until it says what that
  export takes.
  """
  use ExUnit.Case, async: true

  alias Argus.Schema
  alias Argus.Schema.Reads

  @internal [module_info: 0, module_info: 1, __info__: 1]

  # The modules every query's code version leaves out: exactly those
  # whose every export this checks.
  defp schema_modules do
    for mod <- Application.spec(:argus_beam, :modules),
        Argus.Graph.Reads.schema_module?(mod),
        do: mod
  end

  defp exports(mod), do: Enum.sort(mod.module_info(:exports) -- @internal)

  # Every relation, and a name that is none: a read of an absent
  # relation is a read too, and a later schema may add it.
  defp relation_names, do: Enum.map(Schema.names(), &[&1]) ++ [[:schema_reads_test_absent]]

  defp arguments(Schema, :fetch, 1), do: relation_names()
  defp arguments(Schema, :columns, 1), do: relation_names()

  defp arguments(Schema, :datalog_decls, 1),
    do: Enum.map([:layer_1, :layer_2, :layer_3, :all], &[&1])

  # Every read the other exports record, and one naming a relation that
  # is no atom in this VM (as a manifest written elsewhere may).
  defp arguments(Schema, :reread, 1) do
    absent = "fetch schema_reads_test_#{System.unique_integer([:positive])}"
    Enum.map([absent | recorded_reads()], &[&1])
  end

  defp arguments(_mod, _fun, 0), do: [[]]
  defp arguments(_mod, _fun, _arity), do: :unknown

  defp recorded_reads do
    for mod <- schema_modules(),
        {fun, arity} <- exports(mod),
        {mod, fun, arity} != {Schema, :reread, 1},
        args <- List.wrap(arguments(mod, fun, arity)),
        is_list(args),
        {_value, reads} = Reads.track(fn -> apply(mod, fun, args) end),
        read <- reads,
        uniq: true,
        do: read
  end

  test "the schema's modules are Argus.Schema and its concern modules" do
    modules = schema_modules()
    assert Schema in modules
    assert Argus.Schema.Bytecode in modules
    assert length(modules) > 10
  end

  test "every export records a read of exactly what it returns" do
    calls =
      for mod <- schema_modules(), {fun, arity} <- exports(mod) do
        case arguments(mod, fun, arity) do
          :unknown ->
            flunk("""
            #{inspect(mod)}.#{fun}/#{arity} takes arguments this test does not know. \
            Everything under Argus.Schema is data a producer's key names by the reads \
            it records (Argus.Schema.Reads): list its valid arguments in arguments/3, \
            or move code that is not schema data out of the namespace.\
            """)

          arguments ->
            for args <- arguments do
              {value, reads} = Reads.track(fn -> apply(mod, fun, args) end)
              call = "#{inspect(mod)}.#{fun}(#{Enum.map_join(args, ", ", &inspect/1)})"

              assert reads != [], "#{call} returns schema data and records no read"

              assert Enum.any?(reads, &(Schema.reread(&1) === value)),
                     "#{call} records #{inspect(reads)}, none of which names what it returns"

              for read <- reads do
                refute match?({:unknown_read, _}, Schema.reread(read)),
                       "#{call} records #{inspect(read)}, which reread/1 does not answer"
              end

              call
            end
        end
      end

    assert length(List.flatten(calls)) > 2 * length(Schema.names())
  end

  test "a read made through another module is recorded in the callee" do
    rows = %{bif_call: [["M:f/0#1", "M:f/0", "erlang", "self", "0", "0"]], custom: [["x"]]}
    {_typed, reads} = Reads.track(fn -> Argus.Facts.decode(rows) end)
    assert reads == ["columns bif_call", "columns custom"]

    {_typed, reads} = Reads.track(fn -> apply(Schema, :columns, [:bif_call]) end)
    assert reads == ["columns bif_call"]
  end
end
