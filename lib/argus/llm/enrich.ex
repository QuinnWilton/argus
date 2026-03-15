defmodule Argus.LLM.Enrich do
  @moduledoc """
  Semantic enrichment of `:dynamic` values in extracted facts.

  Scans `.facts` files for rows containing `"dynamic"` in known relations,
  reconstructs the bytecode context around each site from the `instruction`,
  `move`, and `literal_value` facts, and asks an LLM to resolve the value.

  Enriched values are written back with a `~` prefix (e.g., `~MyApp.Cache`),
  so existing rules that filter `!= "dynamic"` automatically include them,
  while rules can opt out by also filtering against the `~` prefix.
  """

  @batch_size 20

  # Relations with enrichable dynamic fields.
  # Each entry: {relation_name, field_index (0-based), description for the LLM}.
  @enrichable [
    {"sync_call", 1, "GenServer target module"},
    {"async_cast", 1, "GenServer target module"},
    {"sync_call_timeout", 1, "GenServer target module"},
    {"ets_new", 2, "ETS table name atom"},
    {"ets_op", 2, "ETS table reference"},
    {"process_link", 1, "linked process module"},
    {"process_monitor", 1, "monitored process module"}
  ]

  @doc """
  Enriches dynamic values in `.facts` files using LLM analysis.

  Scans the facts directory for rows containing `"dynamic"` in enrichable
  relations, reconstructs bytecode context, and writes resolved values back.

  When `:enrich_audit` is true (or an audit path is given), writes an audit
  log to `_enrich_audit.tsv` in the facts directory. Each row records:

      relation \\t func_id \\t original_value \\t resolved_value \\t context_snippet

  This lets you review every LLM decision after the fact.

  Returns `:ok` or `{:error, reason}`.

  ## Options

  - `:enrich_audit` — `true` to write audit log to facts dir, or a path string
  """
  @spec enrich(Path.t(), keyword()) :: :ok | {:error, term()}
  def enrich(facts_dir, opts \\ []) do
    with {:ok, sites} <- scan_dynamic_sites(facts_dir),
         {:ok, context} <- load_context_facts(facts_dir) do
      if sites == [] do
        maybe_write_audit([], facts_dir, opts)
        :ok
      else
        sites_with_context = attach_context(sites, context)
        resolve_and_write(sites_with_context, facts_dir, opts)
      end
    end
  end

  @doc """
  Scans facts files and returns all dynamic sites found.

  Useful for testing without running the LLM.
  """
  @spec scan_dynamic_sites(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def scan_dynamic_sites(facts_dir) do
    sites =
      Enum.flat_map(@enrichable, fn {relation, field_idx, description} ->
        path = Path.join(facts_dir, "#{relation}.facts")

        case File.read(path) do
          {:ok, content} ->
            content
            |> String.split("\n", trim: true)
            |> Enum.with_index()
            |> Enum.flat_map(fn {line, line_idx} ->
              fields = String.split(line, "\t")

              if Enum.at(fields, field_idx) == "dynamic" do
                [
                  %{
                    relation: relation,
                    field_idx: field_idx,
                    field_desc: description,
                    line_idx: line_idx,
                    fields: fields,
                    func_id: extract_func_id(relation, fields)
                  }
                ]
              else
                []
              end
            end)

          {:error, :enoent} ->
            []

          {:error, reason} ->
            throw({:scan_error, relation, reason})
        end
      end)

    {:ok, sites}
  catch
    {:scan_error, relation, reason} -> {:error, {:scan_failed, relation, reason}}
  end

  @doc """
  Builds the enrichment prompt for a batch of sites.

  Useful for testing prompt construction.
  """
  @spec build_prompt([map()]) :: String.t()
  def build_prompt(sites_with_context) do
    site_sections =
      sites_with_context
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {site, idx} ->
        register_desc = "#{site.field_desc}"

        instructions =
          case site[:context_instructions] do
            nil -> "(no instruction context available)"
            instrs -> Enum.map_join(instrs, "\n", fn i -> "  #{i}" end)
          end

        """
        ## Site #{idx}
        Function: #{site.func_id}
        Relation: #{site.relation}, field index #{site.field_idx}
        Resolve: #{register_desc}
        Instructions:
        #{instructions}\
        """
      end)

    """
    Determine the BEAM register values at each call site below.
    Each site shows the function, surrounding instructions, and the register to resolve.
    Respond with one JSON object per line: {"site": 1, "value": "MyApp.Cache"}
    If you cannot determine the value, respond with {"site": 1, "value": "dynamic"}

    #{site_sections}\
    """
  end

  # Extract the function ID from a fact row based on the relation.
  defp extract_func_id(relation, fields) when relation in ["sync_call", "async_cast"] do
    Enum.at(fields, 0)
  end

  defp extract_func_id("sync_call_timeout", fields), do: Enum.at(fields, 0)

  defp extract_func_id(relation, fields) when relation in ["ets_new", "ets_op"],
    do: Enum.at(fields, 1)

  defp extract_func_id(relation, _fields) when relation in ["process_link", "process_monitor"],
    do: nil

  defp extract_func_id(_relation, _fields), do: nil

  # Load instruction, move, and literal_value facts for context reconstruction.
  defp load_context_facts(facts_dir) do
    with {:ok, instructions} <- read_facts_file(facts_dir, "instruction"),
         {:ok, moves} <- read_facts_file(facts_dir, "move"),
         {:ok, literals} <- read_facts_file(facts_dir, "literal_value") do
      {:ok, %{instructions: instructions, moves: moves, literals: literals}}
    end
  end

  defp read_facts_file(facts_dir, relation) do
    path = Path.join(facts_dir, "#{relation}.facts")

    case File.read(path) do
      {:ok, content} ->
        rows =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, "\t"))

        {:ok, rows}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, relation, reason}}
    end
  end

  # Attach surrounding instruction context to each dynamic site.
  defp attach_context(sites, context) do
    # Build instruction index by func_id for fast lookup.
    by_func =
      Enum.group_by(context.instructions, fn [_id, func | _] -> func end)

    # Index moves and literals by instruction ID.
    moves_by_id =
      Enum.group_by(context.moves, fn [id | _] -> id end)

    literals_by_id =
      Enum.group_by(context.literals, fn [id | _] -> id end)

    Enum.map(sites, fn site ->
      case site.func_id do
        nil ->
          site

        func_id ->
          func_instrs =
            Map.get(by_func, func_id, [])
            |> Enum.sort_by(fn [_id, _func, idx | _] -> String.to_integer(idx) end)

          # Format ~15 instructions around context with move/literal annotations.
          formatted = format_context_instructions(func_instrs, moves_by_id, literals_by_id)
          Map.put(site, :context_instructions, formatted)
      end
    end)
  end

  defp format_context_instructions(func_instrs, moves_by_id, literals_by_id) do
    Enum.map(func_instrs, fn [id, _func, idx, op] ->
      extras =
        (Map.get(moves_by_id, id, []) |> Enum.map(fn [_, src, dst] -> "#{src} -> #{dst}" end)) ++
          (Map.get(literals_by_id, id, []) |> Enum.map(fn [_, reg, val] -> "#{reg} = #{val}" end))

      extra_str = if extras == [], do: "", else: " [#{Enum.join(extras, ", ")}]"
      "##{idx}: #{op}#{extra_str}"
    end)
  end

  # Batch sites, send to LLM, parse responses, write back, and optionally audit.
  defp resolve_and_write(sites_with_context, facts_dir, opts) do
    resolved =
      sites_with_context
      |> Enum.chunk_every(@batch_size)
      |> Enum.flat_map(fn batch ->
        case resolve_batch(batch, opts) do
          {:ok, values} -> Enum.zip(batch, values)
          {:error, _} -> Enum.map(batch, &{&1, "dynamic"})
        end
      end)

    # Write audit log before rewriting facts so the log captures
    # the before/after in one place.
    maybe_write_audit(resolved, facts_dir, opts)

    # Group resolved values by relation for efficient file rewriting.
    by_relation = Enum.group_by(resolved, fn {site, _val} -> site.relation end)

    Enum.reduce_while(by_relation, :ok, fn {relation, entries}, :ok ->
      case rewrite_facts_file(facts_dir, relation, entries) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_batch(batch, opts) do
    prompt_text = build_prompt(batch)

    case Argus.LLM.prompt(prompt_text, opts) do
      {:ok, response} ->
        values = parse_response(response, length(batch))
        {:ok, values}

      {:error, _} = error ->
        error
    end
  end

  # Parse line-by-line JSON responses from the LLM.
  defp parse_response(response, expected_count) do
    parsed =
      response
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        # Match {"site": N, "value": "..."} pattern.
        case Regex.run(~r/"site"\s*:\s*(\d+)\s*,\s*"value"\s*:\s*"([^"]*)"/, line) do
          [_, site_str, value] ->
            [{String.to_integer(site_str), value}]

          nil ->
            []
        end
      end)
      |> Map.new()

    # Return values in order, defaulting to "dynamic" for missing sites.
    Enum.map(1..expected_count//1, fn idx ->
      case Map.get(parsed, idx) do
        nil -> "dynamic"
        "dynamic" -> "dynamic"
        value -> "~#{value}"
      end
    end)
  end

  # ── Audit log ──────────────────────────────────────────────────────

  defp maybe_write_audit(resolved, facts_dir, opts) do
    case audit_path(facts_dir, opts) do
      nil -> :ok
      path -> write_audit(resolved, path)
    end
  end

  defp audit_path(facts_dir, opts) do
    case Keyword.get(opts, :enrich_audit) do
      true -> Path.join(facts_dir, "_enrich_audit.tsv")
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  defp write_audit(resolved, path) do
    header = "relation\tfunc_id\tfield\toriginal\tresolved\tcontext\n"

    rows =
      Enum.map_join(resolved, "\n", fn {site, value} ->
        context_snippet =
          case site[:context_instructions] do
            nil -> ""
            instrs -> instrs |> Enum.take(10) |> Enum.join(" | ")
          end

        Enum.join(
          [
            site.relation,
            site.func_id || "",
            site.field_desc,
            "dynamic",
            value,
            context_snippet
          ],
          "\t"
        )
      end)

    File.write(path, header <> rows <> "\n")
  end

  # Rewrite a .facts file, replacing dynamic values with enriched ones.
  defp rewrite_facts_file(facts_dir, relation, entries) do
    path = Path.join(facts_dir, "#{relation}.facts")

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        # Build a map from line_idx to {field_idx, new_value}.
        replacements =
          Map.new(entries, fn {site, value} ->
            {site.line_idx, {site.field_idx, value}}
          end)

        new_lines =
          lines
          |> Enum.with_index()
          |> Enum.map(fn {line, idx} ->
            case Map.get(replacements, idx) do
              nil ->
                line

              {field_idx, new_value} when new_value != "dynamic" ->
                fields = String.split(line, "\t")
                List.replace_at(fields, field_idx, new_value) |> Enum.join("\t")

              _ ->
                line
            end
          end)

        case File.write(path, Enum.join(new_lines, "\n")) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rewrite_failed, relation, reason}}
        end

      {:error, reason} ->
        {:error, {:rewrite_failed, relation, reason}}
    end
  end
end
