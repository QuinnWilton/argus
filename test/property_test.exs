defmodule Argus.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Pipeline.Normalize
  alias Argus.Extractor.Helpers

  # ── Generators ──────────────────────────────────────────────────────

  defp module_name do
    gen all(segments <- list_of(atom(:alphanumeric), min_length: 1, max_length: 3)) do
      Module.concat(segments)
    end
  end

  defp function_name do
    atom(:alphanumeric)
  end

  defp arity do
    integer(0..255)
  end

  defp register do
    gen all(
          kind <- member_of([:x, :y]),
          n <- integer(0..15)
        ) do
      {kind, n}
    end
  end

  # Simple instructions that don't contain typed registers or alloc hints.
  defp simple_instruction do
    one_of([
      constant(:return),
      map(positive_integer(), &{:label, &1}),
      bind(register(), fn src ->
        map(register(), fn dst -> {:move, src, dst} end)
      end),
      bind(member_of([{:atom, :ok}, {:atom, :error}, {:integer, 42}]), fn a ->
        map(register(), fn dst -> {:move, a, dst} end)
      end),
      map(positive_integer(), &{:line, &1})
    ])
  end

  # Instructions with typed register wrappers.
  defp typed_instruction do
    gen all(
          inner <- register(),
          type <- member_of([{:t_integer, :any}, {:t_atom, :any}, {:t_map, :any, :any}]),
          dst <- register()
        ) do
      {:move, {:tr, inner, type}, dst}
    end
  end

  # Instructions with alloc hints.
  defp alloc_instruction do
    gen all(
          words <- integer(0..100),
          floats <- constant(0),
          funs <- integer(0..10),
          stack <- integer(0..20),
          live <- integer(0..10)
        ) do
      {:allocate_heap, stack, {:alloc, [words: words, floats: floats, funs: funs]}, live}
    end
  end

  defp beam_instruction do
    frequency([
      {6, simple_instruction()},
      {2, typed_instruction()},
      {1, alloc_instruction()}
    ])
  end

  defp beam_function do
    gen all(
          mod <- module_name(),
          name <- function_name(),
          ar <- arity(),
          instrs <- list_of(beam_instruction(), min_length: 1, max_length: 20)
        ) do
      {mod, {:function, name, ar, 1, instrs}}
    end
  end

  # ── Property: normalize preserves instruction count ─────────────────

  describe "normalize_function/2" do
    property "output length equals input instruction count" do
      check all({mod, func} <- beam_function()) do
        {:function, _, _, _, instrs} = func
        result = Normalize.normalize_function(mod, func)
        assert length(result) == length(instrs)
      end
    end

    property "all IDs match mod:func/arity#idx pattern" do
      check all({mod, func} <- beam_function()) do
        {:function, name, ar, _, _} = func
        expected_prefix = "#{inspect(mod)}:#{name}/#{ar}#"

        for {id, _instr} <- Normalize.normalize_function(mod, func) do
          assert String.starts_with?(id, expected_prefix),
                 "expected ID to start with #{expected_prefix}, got: #{id}"
        end
      end
    end

    property "IDs have sequential indices" do
      check all({mod, func} <- beam_function()) do
        {:function, _, _, _, instrs} = func
        result = Normalize.normalize_function(mod, func)

        indices =
          Enum.map(result, fn {id, _} ->
            id |> String.split("#") |> List.last() |> String.to_integer()
          end)

        assert indices == Enum.to_list(0..(length(instrs) - 1))
      end
    end

    property "normalizing is idempotent (no typed registers or alloc hints remain)" do
      check all({mod, func} <- beam_function()) do
        normalized = Normalize.normalize_function(mod, func)

        for {_id, instr} <- normalized do
          refute has_typed_register?(instr),
                 "typed register found after normalization: #{inspect(instr)}"

          refute has_alloc_hint?(instr),
                 "alloc hint found after normalization: #{inspect(instr)}"
        end
      end
    end
  end

  # ── Property: add_fact accumulation ─────────────────────────────────

  describe "add_fact/3" do
    property "calling add_fact n times produces n rows" do
      check all(
              n <- integer(1..50),
              relation <- atom(:alphanumeric),
              rows <-
                list_of(list_of(string(:alphanumeric, min_length: 1), min_length: 1), length: n)
            ) do
        result = Enum.reduce(rows, %{}, fn row, acc -> Helpers.add_fact(acc, relation, row) end)
        assert length(result[relation]) == n
      end
    end

    property "rows are prepended (most recent first)" do
      check all(
              relation <- atom(:alphanumeric),
              rows <-
                list_of(list_of(string(:alphanumeric, min_length: 1), min_length: 1),
                  min_length: 2,
                  max_length: 10
                )
            ) do
        result = Enum.reduce(rows, %{}, fn row, acc -> Helpers.add_fact(acc, relation, row) end)
        assert result[relation] == Enum.reverse(rows)
      end
    end
  end

  # ── Property: resolve_register with atoms ───────────────────────────

  describe "resolve_register/3" do
    property "moving an atom to a register then resolving returns that atom" do
      check all(
              atom_val <- atom(:alphanumeric),
              reg <- register()
            ) do
        instrs = [{:move, {:atom, atom_val}, reg}, :return]
        # Resolve at index 1 (the return), looking for reg.
        assert {:ok, ^atom_val} = Helpers.resolve_register(instrs, 1, reg)
      end
    end

    property "moving an integer to a register then resolving returns that integer" do
      check all(
              int_val <- integer(),
              reg <- register()
            ) do
        instrs = [{:move, {:integer, int_val}, reg}, :return]
        assert {:ok, ^int_val} = Helpers.resolve_register(instrs, 1, reg)
      end
    end

    property "resolving an unwritten register returns :dynamic" do
      check all(target <- register()) do
        # Only a label and return — no moves.
        instrs = [{:label, 1}, :return]
        assert :dynamic = Helpers.resolve_register(instrs, 1, target)
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp has_typed_register?({:tr, _, _}), do: true

  defp has_typed_register?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&has_typed_register?/1)
  end

  defp has_typed_register?(list) when is_list(list) do
    Enum.any?(list, &has_typed_register?/1)
  end

  defp has_typed_register?(_), do: false

  defp has_alloc_hint?({:alloc, kw}) when is_list(kw), do: true

  defp has_alloc_hint?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&has_alloc_hint?/1)
  end

  defp has_alloc_hint?(list) when is_list(list) do
    Enum.any?(list, &has_alloc_hint?/1)
  end

  defp has_alloc_hint?(_), do: false
end
