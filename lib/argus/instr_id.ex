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

  ## The wire format lives here

  `mint/2` and `func_id/2,3` are the only places that construct these
  strings, and `parse/1` and `parse_func/1` are their inverses. Everything
  that emits an ID — `Normalize` for Layer 1, eight Layer-2 extractors, and
  `format/1` itself — goes through them.

  That matters because the ID scheme is the single most invasive thing in
  the fact schema: an instruction's index is a raw offset into its
  function's instruction list, so it renumbers whenever the function's body
  changes, and 49 of the 78 relations carry one. Any future change to how
  instructions are named — content-derived keys, block-relative addressing —
  has to be able to move one definition rather than nineteen interpolations
  scattered across the extractors.
  """

  use Argus.Purity

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
  @pure true
  def parse(id) when is_binary(id) do
    with {:ok, prefix, idx} <- split_trailing_int(id, "#"),
         {:ok, mod_func, arity} <- split_trailing_int(prefix, "/"),
         {:ok, module, func} <- split_last(mod_func, ":") do
      {:ok, %__MODULE__{module: module, func: func, arity: arity, idx: idx}}
    end
  end

  @doc """
  Build an instruction ID from a function ID and an instruction index.

  The one place instruction IDs are constructed. `idx` is the instruction's
  offset within its function's normalized instruction list — positional by
  construction, which is why callers must not derive meaning from it beyond
  ordering within one function.

      iex> Argus.InstrId.mint("Demo:run/1", 3)
      "Demo:run/1#3"
  """
  @spec mint(String.t(), non_neg_integer()) :: String.t()
  @pure true
  def mint(func_id, idx) when is_binary(func_id) and is_integer(idx) and idx >= 0 do
    func_id <> "#" <> Integer.to_string(idx)
  end

  @doc """
  Build a function ID from a module and an already-joined `name/arity`.

      iex> Argus.InstrId.func_id("Demo", "run/1")
      "Demo:run/1"
  """
  @spec func_id(module() | String.t(), String.t()) :: String.t()
  @pure true
  def func_id(module, name_arity) when is_binary(name_arity) do
    module_string(module) <> ":" <> name_arity
  end

  @doc """
  Build a function ID from a module, function name, and arity.

  The module renders through `inspect/1` when given an atom, so Elixir
  modules read as `Demo` rather than `:"Elixir.Demo"` and Erlang modules as
  `:lists`. That is the form `parse/1` expects back.

      iex> Argus.InstrId.func_id(Demo, :run, 1)
      "Demo:run/1"

      iex> Argus.InstrId.func_id(:lists, :map, 2)
      ":lists:map/2"
  """
  @spec func_id(module() | String.t(), atom() | String.t(), arity()) :: String.t()
  @pure true
  def func_id(module, name, arity) when is_integer(arity) and arity >= 0 do
    func_id(module, to_string(name) <> "/" <> Integer.to_string(arity))
  end

  @doc "Render back to the wire format (inverse of `parse/1`)."
  @spec format(t()) :: String.t()
  @pure true
  def format(%__MODULE__{module: m, func: f, arity: a, idx: i}) do
    mint(func_id(m, f, a), i)
  end

  defp module_string(module) when is_atom(module), do: inspect(module)
  defp module_string(module) when is_binary(module), do: module

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
  @pure true
  def parse_func(func_id) when is_binary(func_id) do
    with {:ok, mod_func, arity} <- split_trailing_int(func_id, "/"),
         {:ok, module, func} <- split_last(mod_func, ":") do
      {:ok, %{module: module, func: func, arity: arity}}
    end
  end

  @doc """
  The function ID containing an instruction ID — the `#idx` suffix removed.

  Right-anchored like `parse/1`, which matters: splitting on the *first*
  `#` truncates a compiler-generated name that contains one, silently
  producing a function ID that joins against nothing (or worse, against
  the wrong function).

      iex> Argus.InstrId.func_id_of("Demo:run/1#3")
      {:ok, "Demo:run/1"}

      iex> Argus.InstrId.func_id_of("Demo:weird#name/1#3")
      {:ok, "Demo:weird#name/1"}

      iex> Argus.InstrId.func_id_of("dynamic")
      :error
  """
  @spec func_id_of(String.t()) :: {:ok, String.t()} | :error
  @pure true
  def func_id_of(instr_id) when is_binary(instr_id) do
    case split_trailing_int(instr_id, "#") do
      {:ok, func_id, _idx} -> {:ok, func_id}
      :error -> :error
    end
  end

  @doc "The `{func, arity}` pair, the usual per-function grouping key."
  @spec fa(t()) :: {String.t(), non_neg_integer()}
  @pure true
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
