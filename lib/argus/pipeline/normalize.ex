defmodule Argus.Pipeline.Normalize do
  @moduledoc """
  Thin normalization pass over disassembled BEAM instructions.

  Assigns globally-unique instruction IDs, canonicalizes allocation variants,
  and strips typed register annotations. The goal is to simplify downstream
  pattern matching in `Argus.Pipeline.Emit` without losing information.

  ## Instruction ID format

  Each instruction gets an ID of the form `"mod:func/arity#idx"` where `idx`
  is the zero-based index within the function body. The format itself is
  owned by `Argus.InstrId` — see `Argus.InstrId.mint/2`.

  ## Normalization rules

  - **Typed registers**: `{:tr, reg, _type}` → `reg`. The type info from the
    compiler is stripped since we derive types from the instruction stream.
  - **Allocation variants**: `allocate_heap`, `allocate_zero`, etc. are
    canonicalized — the heap hint is preserved in a uniform tuple shape.
  - **test_heap**: canonicalized to extract the raw word count from `{:alloc, ...}`.
  - Everything else passes through unchanged with its ID attached.
  """

  alias Argus.InstrId

  @type instruction_id :: String.t()
  @type normalized :: {instruction_id(), term()}

  @doc """
  Normalizes a function's instructions.

  Takes a module name and a function tuple from `:beam_disasm` and returns
  a list of `{id, instruction}` pairs with normalized instructions.
  """
  @spec normalize_function(
          atom(),
          {:function, atom(), non_neg_integer(), non_neg_integer(), list()}
        ) ::
          [normalized()]
  def normalize_function(module, {:function, name, arity, _entry, instructions}) do
    func_id = func_id(module, name, arity)

    instructions
    |> Enum.with_index()
    |> Enum.map(fn {instr, idx} ->
      {InstrId.mint(func_id, idx), normalize_instruction(instr)}
    end)
  end

  @doc """
  Returns the function ID string for a given MFA.
  """
  @spec func_id(atom(), atom(), non_neg_integer()) :: String.t()
  defdelegate func_id(module, name, arity), to: InstrId

  # Strip typed registers recursively in instruction operands.
  defp normalize_instruction(instr) when is_tuple(instr) do
    instr
    |> Tuple.to_list()
    |> Enum.map(&normalize_operand/1)
    |> List.to_tuple()
  end

  defp normalize_instruction(other), do: other

  # Typed register → plain register.
  defp normalize_operand({:tr, reg, _type}), do: reg

  # Allocation hints — normalize {:alloc, [...]} to extract word count.
  defp normalize_operand({:alloc, kw}) when is_list(kw) do
    alloc_words(kw)
  end

  # Recurse into lists (e.g., test args, select case lists) by walking the
  # cons cells rather than with Enum.map.
  #
  # BEAM literals can be IMPROPER lists — `[head | 2]` — for which
  # `is_list/1` is still true but `Enum.map/2` raises FunctionClauseError.
  # Poison ships one, and it took the whole extraction down. Walking cells
  # handles proper and improper alike: the improper tail falls through to
  # the catch-all clause and is preserved as-is, so normalization stays
  # structure-preserving instead of silently properising the literal.
  defp normalize_operand([]), do: []

  defp normalize_operand([head | tail]) do
    [normalize_operand(head) | normalize_operand(tail)]
  end

  # Recurse into tuples (e.g., {:list, [...]}, {:extfunc, ...}).
  defp normalize_operand(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_operand/1)
    |> List.to_tuple()
  end

  # Atoms, integers, etc. pass through.
  defp normalize_operand(other), do: other

  # Total by construction, where `Keyword.get/3` was not: it raises on an
  # improper list, the same hazard that took extraction down on a real
  # literal. An alloc hint without a word count is 0, which is what the
  # keyword default meant anyway.
  defp alloc_words([{:words, n} | _rest]) when is_integer(n), do: n
  defp alloc_words([_other | rest]), do: alloc_words(rest)
  defp alloc_words(_not_a_cons), do: 0
end
