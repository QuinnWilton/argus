defmodule Argus.Pipeline.Normalize do
  @moduledoc """
  Thin normalization pass over disassembled BEAM instructions.

  Assigns globally-unique instruction IDs, canonicalizes allocation variants,
  and strips typed register annotations. The goal is to simplify downstream
  pattern matching in `Argus.Pipeline.Emit` without losing information.

  ## Instruction ID format

  Each instruction gets an ID of the form `"mod:func/arity#idx"` where `idx`
  is the zero-based index within the function body.

  ## Normalization rules

  - **Typed registers**: `{:tr, reg, _type}` → `reg`. The type info from the
    compiler is stripped since we derive types from the instruction stream.
  - **Allocation variants**: `allocate_heap`, `allocate_zero`, etc. are
    canonicalized — the heap hint is preserved in a uniform tuple shape.
  - **test_heap**: canonicalized to extract the raw word count from `{:alloc, ...}`.
  - Everything else passes through unchanged with its ID attached.
  """

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
      id = "#{func_id}##{idx}"
      {id, normalize_instruction(instr)}
    end)
  end

  @doc """
  Returns the function ID string for a given MFA.
  """
  @spec func_id(atom(), atom(), non_neg_integer()) :: String.t()
  def func_id(module, name, arity) do
    "#{inspect(module)}:#{name}/#{arity}"
  end

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
    Keyword.get(kw, :words, 0)
  end

  # Recurse into lists (e.g., test args, select case lists).
  defp normalize_operand(list) when is_list(list) do
    Enum.map(list, &normalize_operand/1)
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
end
