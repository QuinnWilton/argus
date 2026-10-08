defmodule Argus.Extractor.TermValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractors.TermValidation

  setup_all do
    {:ok, facts} =
      Argus.Pipeline.extract([:term_validation_fixture], extractors: [TermValidation])

    %{facts: facts}
  end

  test "recursive list, tuple and map validation belongs to the exact decoded term", %{
    facts: facts
  } do
    assert [
             [_, ":term_validation_fixture:decode/1"],
             [_, ":term_validation_fixture:mixed_copies/2"]
           ] = Enum.sort(facts.decoded_term_validated)

    assert Map.get(facts, :extraction_error, []) == []
  end

  test "the modeled decoder actually rejects nested executable terms" do
    fun = fn -> :executable end

    for unsafe <- [fun, [fun], [1 | fun], {fun}, %{fun => 1}, %{key: fun}] do
      assert {:error, _} = :term_validation_fixture.decode(:erlang.term_to_binary(unsafe))
    end
  end

  property "recursive validation distinguishes executable leaves at arbitrary container paths" do
    check all(
            wrappers <- list_of(member_of([:list, :tuple, :key, :value, :tail]), max_length: 8),
            executable? <- boolean()
          ) do
      leaf = if executable?, do: fn -> :executable end, else: :inert

      term =
        Enum.reduce(wrappers, leaf, fn
          :list, value -> [0, value]
          :tuple, value -> {:nested, value}
          :key, value -> %{value => :inert}
          :value, value -> %{nested: value}
          :tail, value -> [0 | value]
        end)

      decoded = :term_validation_fixture.decode(:erlang.term_to_binary(term))

      if executable?,
        do: assert(match?({:error, _}, decoded)),
        else: assert(decoded == {:ok, term})
    end
  end

  test "exact numeric guards cannot hide an accepting branch" do
    # This is deliberately bytecode-level: a compiler can fold literal tests,
    # but the proof also reaches literals through earlier equality refinements.
    fun = %{
      arity: 1,
      instrs: [
        {:test, :is_eq_exact, {:f, 3}, [{:integer, 1}, {:float, 1.0}]},
        {:move, {:literal, {:error, :rejected}}, {:x, 0}},
        :return,
        {:move, {:atom, :ok}, {:x, 0}},
        :return
      ],
      cfg: %{
        entry: 0,
        blocks: %{
          0 => %{range: {0, 0}, succs: [{1, :branch_pass}, {2, :branch_fail}]},
          1 => %{range: {1, 2}, succs: []},
          2 => %{range: {3, 4}, succs: []}
        }
      }
    }

    refute Argus.Extractors.TermValidation.Proof.proves?(fun, :term, MapSet.new())
  end

  describe "what decoded bytes are" do
    setup do
      {:ok, facts} =
        Argus.Pipeline.extract(
          [Argus.Test.Fixtures.ContractSealed, Argus.Test.Fixtures.ContractUnsealed],
          extractors: [TermValidation]
        )

      rows =
        for [_id, func, pos, param, callee, path] <- facts.decoded_bytes_value,
            do: {func |> String.split(".") |> List.last(), pos, param, callee, path}

      %{rows: rows}
    end

    test "a projection out of a remote result, or a parameter and what its local callers hand it",
         %{rows: rows} do
      assert {"ContractSealed:verified/2", "0", "-1", "Plug.Crypto.MessageVerifier:verify/2",
              "tuple:1"} in rows

      assert {"ContractSealed:token_field/2", "0", "-1", "Phoenix.Token:verify/4",
              ~s(tuple:1/map:"blob")} in rows

      assert {"ContractSealed:safe_decode/1", "0", "0", "", ""} in rows

      # The helper's caller, at the position the helper decodes.
      assert {"ContractSealed:open_default/3", "0", "-1",
              "Plug.Crypto.MessageEncryptor:decrypt/4", "tuple:1"} in rows

      # A join of the payload and the ciphertext is no one value.
      refute Enum.any?(rows, &(elem(&1, 0) == "ContractUnsealed:either/4"))
    end
  end
end
