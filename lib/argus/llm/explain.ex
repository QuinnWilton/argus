defmodule Argus.LLM.Explain do
  @moduledoc """
  LLM-powered explanation of analysis results.

  Builds a structured prompt from the analysis description, output relation
  schemas, findings, and module list, then asks the LLM to explain each
  finding in concrete terms.
  """

  alias Argus.Analysis

  @max_rows 50

  @doc """
  Explains analysis results using an LLM.

  Builds a prompt with the analysis context and findings, sends it to the
  LLM, and returns the explanation text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec explain(Analysis.result(), Analysis.analysis(), [atom()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def explain(results, analysis, modules, opts \\ []) do
    case build_prompt(results, analysis, modules) do
      {:ok, prompt_text} ->
        Argus.LLM.prompt(prompt_text, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Builds the explanation prompt without sending it to the LLM.

  Useful for testing prompt construction.
  """
  @spec build_prompt(Analysis.result(), Analysis.analysis(), [atom()]) ::
          {:ok, String.t()} | {:error, term()}
  def build_prompt(results, analysis, modules) do
    with {:ok, {name, description, output_relations}} <- resolve_analysis_info(analysis) do
      # Filter to non-empty output relations (skip metadata keys like _argus_mode).
      findings = build_findings(results, output_relations)

      if findings == "" do
        {:error, :no_findings}
      else
        prompt =
          [
            "You are a BEAM/Elixir static analysis expert explaining findings from Argus.\n",
            "## Analysis: #{name}\n#{description}\n",
            format_output_relations(output_relations),
            "## Findings\n#{findings}\n",
            "## Modules analyzed\n#{format_modules(modules)}\n",
            "Explain each finding: what it means, why it matters, and how to fix it.\n",
            "Be specific to the actual module and function names. Be concise."
          ]
          |> Enum.join("\n")

        {:ok, prompt}
      end
    end
  end

  defp resolve_analysis_info({:custom, _path}) do
    {:ok, {"custom", "custom Datalog analysis", []}}
  end

  defp resolve_analysis_info(name) when is_atom(name) do
    case Analysis.fetch_module(name) do
      {:ok, mod} ->
        {:ok, {to_string(mod.name()), mod.description(), mod.output_relations()}}

      :error ->
        {:error, {:unknown_analysis, name}}
    end
  end

  defp format_output_relations([]), do: ""

  defp format_output_relations(relations) do
    formatted =
      Enum.map_join(relations, "\n", fn rel ->
        fields_str =
          Enum.map_join(rel.fields, ", ", fn {fname, ftype, fdoc} ->
            "#{fname}: #{ftype} — #{fdoc}"
          end)

        ".decl #{rel.name}(#{fields_str})\n#{rel.doc}"
      end)

    "## Output relations\n#{formatted}\n"
  end

  defp build_findings(results, output_relations) do
    # Build a lookup from relation name string to field definitions.
    field_lookup =
      Map.new(output_relations, fn rel ->
        {to_string(rel.name), rel.fields}
      end)

    results
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "_") end)
    |> Enum.reject(fn {_, rows} -> rows == [] end)
    |> Enum.map_join("\n", fn {relation, rows} ->
      fields = Map.get(field_lookup, relation)
      capped = Enum.take(rows, @max_rows)

      row_lines =
        Enum.map_join(capped, "\n", fn row ->
          "  " <> format_row(row, fields)
        end)

      truncated =
        if length(rows) > @max_rows,
          do: "\n  ... (#{length(rows) - @max_rows} more rows)",
          else: ""

      "#{relation}:\n#{row_lines}#{truncated}"
    end)
  end

  # Format a row with field names when available, plain values otherwise.
  defp format_row(row, nil) do
    Enum.join(row, ", ")
  end

  defp format_row(row, fields) do
    row
    |> Enum.zip(fields)
    |> Enum.map_join(", ", fn {val, {fname, _ftype, _fdoc}} ->
      "#{fname}=#{val}"
    end)
  end

  defp format_modules(modules) do
    Enum.map_join(modules, ", ", &inspect/1)
  end
end
