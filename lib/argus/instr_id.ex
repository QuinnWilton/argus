defmodule Argus.InstrId do
  @moduledoc """
  Structured form of an instruction ID (`"Mod:func/arity#idx"`).

  `Argus.Pipeline.Normalize` assigns every instruction a string ID. This module
  parses those strings into a struct so in-process consumers don't have to
  pattern-match on the wire format.

  Parsing is anchored from the **right** — the trailing `#idx`, then the
  trailing `/arity`, then the last `:` separating module from function — so
  compiler-generated function names containing `/`, `#`, or `:` (e.g.
  `-points/2-fun-0-`, quoted atoms) parse correctly. A function name that
  itself contains `:` is inherently ambiguous against an Erlang module name;
  the last-`:` rule matches how the IDs are produced.
  """

  @enforce_keys [:module, :func, :arity, :idx]
  defstruct [:module, :func, :arity, :idx]

  @type t :: %__MODULE__{
          module: String.t(),
          func: String.t(),
          arity: non_neg_integer(),
          idx: non_neg_integer()
        }

  @doc """
  Parse an instruction ID string.

      iex> Argus.InstrId.parse("Demo:run/1#3")
      {:ok, %Argus.InstrId{module: "Demo", func: "run", arity: 1, idx: 3}}

      iex> Argus.InstrId.parse("Demo:-points/2-fun-0-/3#5")
      {:ok, %Argus.InstrId{module: "Demo", func: "-points/2-fun-0-", arity: 3, idx: 5}}

      iex> Argus.InstrId.parse("not an id")
      :error
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(id) when is_binary(id) do
    with {:ok, prefix, idx} <- split_trailing_int(id, "#"),
         {:ok, mod_func, arity} <- split_trailing_int(prefix, "/"),
         {:ok, module, func} <- split_last(mod_func, ":") do
      {:ok, %__MODULE__{module: module, func: func, arity: arity, idx: idx}}
    end
  end

  @doc "Render back to the wire format (inverse of `parse/1`)."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{module: m, func: f, arity: a, idx: i}), do: "#{m}:#{f}/#{a}##{i}"

  @doc """
  Parse a function ID string — an instruction ID without the `#idx` part.

  Function IDs (`"Mod:func/arity"`) are how Layer 2 facts and analysis
  output rows refer to functions. The same right-anchored rules as
  `parse/1` apply.

      iex> Argus.InstrId.parse_func("Demo:-points/2-fun-0-/3")
      {:ok, %{module: "Demo", func: "-points/2-fun-0-", arity: 3}}

      iex> Argus.InstrId.parse_func("dynamic")
      :error
  """
  @spec parse_func(String.t()) ::
          {:ok, %{module: String.t(), func: String.t(), arity: non_neg_integer()}} | :error
  def parse_func(func_id) when is_binary(func_id) do
    with {:ok, mod_func, arity} <- split_trailing_int(func_id, "/"),
         {:ok, module, func} <- split_last(mod_func, ":") do
      {:ok, %{module: module, func: func, arity: arity}}
    end
  end

  @doc "The `{func, arity}` pair, the usual per-function grouping key."
  @spec fa(t()) :: {String.t(), non_neg_integer()}
  def fa(%__MODULE__{func: func, arity: arity}), do: {func, arity}

  # Split on the LAST occurrence of `sep`, requiring a non-negative integer
  # after it.
  defp split_trailing_int(string, sep) do
    with {:ok, left, right} <- split_last(string, sep),
         {int, ""} when int >= 0 <- Integer.parse(right) do
      {:ok, left, int}
    else
      _ -> :error
    end
  end

  defp split_last(string, sep) do
    case :binary.matches(string, sep) do
      [] ->
        :error

      matches ->
        {pos, len} = List.last(matches)
        left = binary_part(string, 0, pos)
        right = binary_part(string, pos + len, byte_size(string) - pos - len)
        if left == "" or right == "", do: :error, else: {:ok, left, right}
    end
  end
end
