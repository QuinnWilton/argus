defmodule Argus.Pipeline.FunctionNamesTest do
  @moduledoc """
  A function of any name extracts: its ID parses back to its name, and
  the rows about it — its definition, the calls to it, the instructions
  in it — spell it the same way. Gleam's `gleam@dynamic` defines
  `nil/0`, which `to_string/1` spells `""`: every instruction of it had
  an ID no parse gave back, and extraction lost the module's facts.
  """

  use ExUnit.Case, async: true

  alias Argus.{InstrId, Pipeline}

  @moduletag :tmp_dir

  @source """
  -module(names).
  -export([nil/0, 'a:b'/1, ''/0, run/0]).

  nil() -> ok.
  'a:b'(X) -> {X, nil()}.
  ''() -> ?MODULE:nil().
  run() -> [nil(), 'a:b'(1), ''()].
  """

  setup %{tmp_dir: dir} do
    erl = Path.join(dir, "names.erl")
    File.write!(erl, @source)

    {:ok, :names, beam} =
      :compile.file(String.to_charlist(erl), [:binary, :debug_info, :return_errors])

    path = Path.join(dir, "names.beam")
    File.write!(path, beam)
    {:ok, facts} = Pipeline.extract([path], format: :typed)
    %{facts: facts}
  end

  test "extraction keeps every function's facts", %{facts: facts} do
    assert Map.get(facts, :extraction_error, []) == []

    names = for row <- facts.function_def, do: row.name

    assert Enum.sort(["nil", "a:b", "", "run"]) ==
             Enum.sort(names -- ["module_info", "module_info"])
  end

  test "each function's ID parses back to its name", %{facts: facts} do
    assert length(facts.function_def) == 6

    for %{func: func_id, name: name, arity: arity} <- facts.function_def do
      assert {:ok, %{module: ":names", func: ^name, arity: ^arity}} = InstrId.parse_func(func_id)
    end

    defined = Enum.map(facts.function_def, & &1.func)
    assert length(facts.instruction) > 6

    for %{id: %InstrId{} = id, func: func} <- facts.instruction do
      assert InstrId.func_id(id.module, id.func, id.arity) == func
      assert func in defined
    end
  end

  test "a call names its callee as the callee's definition does", %{facts: facts} do
    defined = MapSet.new(facts.function_def, & &1.func)

    remote =
      for %{mod: ":names", func: func, arity: arity} <- facts.remote_call,
          do: InstrId.func_id(":names", func, arity)

    local = for %{target: target} <- facts.local_call, do: target

    assert remote == [":names:nil/0"]

    assert Enum.sort(local) ==
             Enum.sort([":names:nil/0", ":names:nil/0", ":names:a:b/1", ":names:/0"])

    assert Enum.all?(remote ++ local, &MapSet.member?(defined, &1))
  end
end
