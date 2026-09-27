defmodule Argus.Lines do
  @moduledoc """
  Resolves anchor IDs to source lines using `line_info` facts.

  Layer 1 stamps every instruction with the source line in effect
  (schema version 3), so an instruction ID resolves to its exact line
  and a function ID to its first stamped line. Build a table once per
  extraction with `from_facts/1` or `from_facts_dir/1`, then `resolve/2`
  the ID forms findings carry: witness-column strings, `Argus.InstrId`
  structs, or MFA tuples.

  Resolution is best-effort by design: IDs from modules without a
  parseable Line chunk, compiler-generated code under a no-location
  marker, and strings that are not IDs at all resolve to `nil`, never a
  guess.
  """

  use Argus.Purity

  alias Argus.InstrId

  @typedoc "Line tables: exact per-instruction plus first-line per function."
  @type t :: %{
          by_instr: %{String.t() => pos_integer()},
          by_func: %{String.t() => pos_integer()}
        }

  @doc """
  Builds line tables from an extracted facts map (raw string rows, as
  returned by `Argus.Pipeline.extract/2` with the default format).
  """
  @spec from_facts(%{atom() => [[String.t()]]}) :: t()
  @pure true
  def from_facts(facts) when is_map(facts) do
    facts |> Map.get(:line_info, []) |> build()
  end

  @doc """
  Builds line tables from a `.facts` directory (the `line_info.facts`
  file written by `Argus.Pipeline.run/3`, empty for modules without a
  Line chunk). A directory without the file is not an extraction's, or
  was changed under this read: it raises `Argus.MissingRelationError`
  rather than resolving every anchor to `nil`.
  """
  @spec from_facts_dir(Path.t()) :: t()
  def from_facts_dir(dir) do
    path = Path.join(dir, "line_info.facts")

    case File.read(path) do
      {:ok, contents} ->
        contents |> Argus.Tsv.decode() |> build()

      {:error, reason} ->
        raise Argus.MissingRelationError, relation: "line_info", path: path, reason: reason
    end
  end

  # One pass: each instruction's line, and each function's least (the
  # function of `"Mod:func/arity#idx"` is what precedes the first `#`).
  defp build(rows) do
    {by_instr, by_func} =
      Enum.reduce(rows, {%{}, %{}}, fn [id, line], {by_instr, by_func} ->
        line = String.to_integer(line)
        [func | _] = :binary.split(id, "#")
        {Map.put(by_instr, id, line), Map.update(by_func, func, line, &min(&1, line))}
      end)

    %{by_instr: by_instr, by_func: by_func}
  end

  @doc """
  Resolves an anchor to its source line, or `nil`.

  Accepts an instruction ID string (`"Mod:func/arity#idx"` — exact
  line), a function ID string (`"Mod:func/arity"` — the function's
  first line), an `Argus.InstrId`, or an MFA tuple. Any other string
  (module names, extractor placeholders like `"dynamic"`) misses both
  tables and resolves to `nil`.
  """
  @spec resolve(t(), String.t() | InstrId.t() | mfa()) :: pos_integer() | nil
  @pure true
  def resolve(lines, %InstrId{} = instr_id) do
    resolve(lines, InstrId.format(instr_id))
  end

  def resolve(lines, {m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    resolve(lines, InstrId.func_id(m, f, a))
  end

  # Map.fetch! rather than `lines.by_instr`. Dot access on a value the
  # compiler cannot prove is a map compiles to a runtime helper that reads a
  # map field OR, if the value turns out to be an atom, calls it as a remote
  # function — a dynamic dispatch behind ordinary-looking syntax. `lines` is
  # a plain map, not a struct, so explicit access is both provable and
  # clearer. Found by running the purity analysis over argus itself.
  def resolve(lines, id) when is_binary(id) do
    Map.get(Map.fetch!(lines, :by_instr), id) ||
      Map.get(Map.fetch!(lines, :by_func), id) ||
      instr_func_fallback(lines, id)
  end

  # An instruction ID whose exact line is unknown (no line in effect at
  # that instruction) still names its function — fall back to its first
  # line rather than nothing.
  defp instr_func_fallback(lines, id) do
    case String.split(id, "#", parts: 2) do
      [func, _idx] -> Map.get(Map.fetch!(lines, :by_func), func)
      _ -> nil
    end
  end

  @doc """
  The line a module is declared on — its `defmodule`, or its `-module`
  attribute — or `nil` when the beam does not say.

  A finding about a module as a whole (a supervisor registered as a
  worker, a later sibling in a start order) carries no function, and
  line 1 of its file is another module's line when the file defines
  several. No instruction carries the declaration: the Line chunk
  records function bodies only, and every function a module's compiler
  adds (`__info__/1`, `module_info/0`) is under the no-location marker.
  The debug info has it: an Elixir module's definition map holds the
  `defmodule` line in `:anno` (`:line` in older Elixirs), an Erlang
  module's abstract code its `-module` attribute. A beam compiled
  without debug info yields `nil`, and so does a line of 0.

  Read from the beam, not from the facts: the debug info is the bulk of
  an Elixir beam (decoding it costs a fifth of a disassembly), and only
  the few modules a module-level finding names ask. `beam` is a `.beam`
  path or the beam's bytes.
  """
  @spec declaration_line(Path.t() | binary()) :: pos_integer() | nil
  def declaration_line(beam) when is_binary(beam) do
    case Argus.Extractor.Helpers.debug_info(%{beam: beam}) do
      {:ok, {:debug_info_v1, backend, data}} -> declared_at(backend, data)
      _ -> nil
    end
  end

  defp declared_at(:elixir_erl, {:elixir_v1, %{} = definition, _specs}) do
    definition
    |> Map.get(:anno, Map.get(definition, :line))
    |> anno_line()
  end

  defp declared_at(:erl_abstract_code, {forms, _options}) when is_list(forms) do
    Enum.find_value(forms, fn
      {:attribute, anno, :module, _name} -> anno_line(anno)
      _form -> nil
    end)
  end

  defp declared_at(_backend, _data), do: nil

  defp anno_line(nil), do: nil

  defp anno_line(anno) do
    case :erl_anno.line(anno) do
      line when is_integer(line) and line > 0 -> line
      _ -> nil
    end
  rescue
    # An anno of a shape erl_anno does not take has no line to give.
    _ -> nil
  end
end
