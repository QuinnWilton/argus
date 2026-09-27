defmodule Argus.Graph.Locate do
  @moduledoc """
  Findings placed in the source: the late step, taken from the bytecode
  alone (`Argus.Located`).

    * `line_table(beam_key)` — a module's lines: each instruction's, and
      each function's first (`Argus.Lines`), from its `line_info` rows.
    * `declaration_line(beam_key)` — the line a module is declared on,
      for an anchor that names the module alone (line 1 is another
      module's in a file that defines several), read from the beam's
      debug info only for the modules a finding names.
    * `located({program, analysis})` — the analysis's findings, each
      placed: the file of its anchor's module, its instruction's line
      (else its function's first, else its module's declaration), the
      line a span closes on, and the same for each related frame.

  Findings are line-free, so this is the only query that runs again when
  an edit only moves lines: its module's `line_table` does, and every
  `located` that placed a finding there. What only the source says — a
  finding's `at_source` token, a span its `to_block` closes, the keyword
  for `{guard}` — is the renderer's (`Argus.Driver.Result`).
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.{Frontend, Pack}
  alias Argus.InstrId
  alias Argus.Located
  alias Roux.Runtime

  defquery :line_table,
    key: beam_key,
    store: :blob,
    returns: {:ok, Argus.Lines.t()} | {:error, term()} do
    case Runtime.query(db, :module_facts, beam_key) do
      {:ok, %{pack: pack}} ->
        # Kept in the store's action cache by the pack and the code
        # that reads it: a session placing findings in a module whose
        # facts it found again reads the table back, not the pack.
        Roux.Blob.cached(db.blob, {__MODULE__, :line_table, table_code(), pack}, fn ->
          case Pack.read(db.blob, pack) do
            {:ok, contents} ->
              rows = contents |> Pack.chunk(:line_info) |> Argus.Tsv.decode()
              {:ok, Argus.Lines.from_facts(%{line_info: rows})}

            :miss ->
              {:error, {:pack_missing, pack}}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  # The code a line table is made by: an edit to it makes tables anew.
  defp table_code, do: for(module <- [Pack, Argus.Tsv, Argus.Lines], do: module.module_info(:md5))

  defquery :declaration_line, key: beam_key, returns: pos_integer() | nil do
    case Runtime.query(db, :module_beam, beam_key) do
      {:ok, beam} -> beam |> Frontend.read() |> Argus.Lines.declaration_line()
      :external -> nil
    end
  end

  defquery :located,
    key: {program, analysis},
    transient: &match?({:error, _}, &1),
    returns: {:ok, [Located.t()]} | {:error, term()} do
    case Runtime.query(db, :findings, {program, analysis}) do
      {:ok, findings, _failures} ->
        modules = Runtime.query(db, :program_modules, program)
        {:ok, Enum.map(findings, &locate(db, modules, &1))}

      {:error, _} = error ->
        error
    end
  end

  defp locate(db, modules, finding) do
    %{file: file, line: line, end_line: end_line} = place(db, modules, finding)

    %Located{
      finding: finding,
      file: file,
      line: line,
      end_line: end_line,
      related: Enum.map(Map.get(finding, :related, []), &place(db, modules, &1))
    }
  end

  # The file of the anchor's module, the anchor's line and, when it
  # closes a span, the line the span ends on; nowhere for an anchor
  # outside the program.
  defp place(db, modules, anchored) do
    with module when module != nil <- anchor_module(anchored),
         {:ok, key} <- Map.fetch(modules, module),
         path when is_binary(path) <- Runtime.query(db, :module_source, key) do
      line = anchor_line(db, key, anchored)
      %{file: path, line: line, end_line: span_end_line(db, key, anchored, line)}
    else
      _ -> Located.nowhere()
    end
  end

  # A finding or frame that closes a span names a second instruction;
  # its line is where the bracket ends. Nil when there is no span, or
  # the end resolves no later than the start.
  defp span_end_line(db, key, anchored, start) do
    with %InstrId{} = to <- Map.get(anchored, :to_instr),
         {:ok, table} <- Runtime.query(db, :line_table, key),
         line when is_integer(line) and line > start <- instr_line(table, to) do
      line
    else
      _ -> nil
    end
  end

  # InstrId fields are the fact-encoded strings ("Depot.Archive"), not
  # atoms: the module an anchor resolves through comes from the
  # finding's module or mfa (atoms, present whenever the instr parsed).
  defp anchor_module(%{module: module}) when is_atom(module) and module != nil, do: module
  defp anchor_module(%{mfa: {module, _f, _a}}) when is_atom(module), do: module
  defp anchor_module(_), do: nil

  # Instruction ID → exact line; MFA → the function's first line;
  # module-only, or a function with no line of its own (one the
  # compiler wrote), → the line the module is declared on; line 1 when
  # the beam carries no debug info to say.
  defp anchor_line(db, key, anchored) do
    line =
      case Runtime.query(db, :line_table, key) do
        {:ok, table} ->
          instr_line(table, Map.get(anchored, :instr)) || mfa_line(table, Map.get(anchored, :mfa))

        {:error, _} ->
          nil
      end

    line || Runtime.query(db, :declaration_line, key) || 1
  end

  defp instr_line(_table, nil), do: nil

  # By the ids' own spelling (`Argus.InstrId`): a function named `nil`
  # is `nil/0` there, where interpolating the atom writes `/0`.
  defp instr_line(table, %InstrId{module: m, func: f, arity: a} = instr) do
    Map.get(table.by_instr, InstrId.format(instr)) ||
      Map.get(table.by_func, InstrId.func_id(m, f, a))
  end

  defp mfa_line(_table, nil), do: nil
  defp mfa_line(table, {m, f, a}), do: Map.get(table.by_func, InstrId.func_id(m, f, a))
end
