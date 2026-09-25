defmodule Argus.FindingHeadsTest do
  @moduledoc """
  Every row shape a rule can emit renders through a real builder clause.

  The shapes are read off the Datalog sources, not listed by hand: each
  rule head of an output relation fixes some columns to literals
  (`blocks_on_peer(mod, "init", callee, "call", "unknown", "", "",
  "conditional")`), and every combination of those literals — with the
  remaining columns either one of the alternatives the column's doc
  declares (`"rescue | erpc_transport | rpc"`) or a placeholder — must
  reach a `finding/2` (or `evidence/2`) clause that renders it — and an
  error-severity finding must say what to do (`help`). A new head whose
  literals no clause matches fails here rather than in a user's project,
  where it would be reported with its raw columns.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis

  @dl_root Path.join(:code.priv_dir(:panoptes), "dl")

  # Placeholder values a free column takes, all at once per attempt: a
  # builder that needs a number, an instruction ID or an empty site
  # renders under at least one of them.
  @fillers ["M:f/1#3", "M:f/1", "M", "", "dynamic", "3"]

  for mod <- Analysis.builtin_analysis_modules(),
      function_exported?(mod, :rules_file, 0),
      function_exported?(mod, :finding, 2) do
    @mod mod

    test "#{inspect(mod)}: every head's row shape renders" do
      heads = heads(@mod)

      for relation <- @mod.output_relations() do
        shapes = Map.get(heads, Atom.to_string(relation.name), [])
        assert shapes != [], "#{relation.name} is an output with no rule head in its .dl"

        # A re-tier relation's rows move the analysis's findings and
        # render nothing of their own (Argus.Findings.Tooling).
        for shape <- shapes,
            not Map.has_key?(relation, :retier),
            row <- expand(relation, shape) do
          assert_renders(@mod, relation, row)
        end
      end
    end
  end

  test "the head parser reads literals, placeholders and expressions" do
    source = """
    // blocks_on_peer(x, "commented") :- nothing.
    .decl blocks_on_peer(a: symbol)
    blocks_on_peer(mod, "init", cat(api, ".", op), "") :-
      thing(mod, "not, a head").
    fact("a", "b").
    """

    assert heads_in(source) == %{
             "blocks_on_peer" => [[:free, {:lit, "init"}, :free, {:lit, ""}]],
             "fact" => [[{:lit, "a"}, {:lit, "b"}]]
           }
  end

  # ── Rendering ───────────────────────────────────────────────────────

  defp assert_renders(mod, relation, row_template) do
    attempts =
      for filler <- @fillers do
        row = Enum.map(row_template, fn value -> if value == :free, do: filler, else: value end)
        {row, render(mod, relation, row)}
      end

    rendered = for {_row, {:ok, attrs}} <- attempts, do: attrs

    if rendered == [] do
      flunk(
        "#{inspect(mod)}.#{relation.name}: no clause renders #{inspect(row_template)}:\n" <>
          Enum.map_join(attempts, "\n", fn {row, {:error, e}} ->
            "  #{inspect(row)} → #{Exception.format_banner(:error, e)}"
          end)
      )
    end

    # An error says what to do about it.
    for %{severity: :error} = attrs <- rendered do
      assert attrs.help != [],
             "#{inspect(mod)}.#{relation.name} is an error with no help: #{attrs.title}"
    end

    for attrs <- rendered, module <- modules(attrs), module != nil do
      name = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

      refute String.contains?(name, [":", "/"]),
             "#{inspect(mod)}.#{relation.name} invented module #{inspect(module)}"
    end
  end

  defp render(mod, relation, row) do
    builder = if Map.has_key?(relation, :evidence), do: :evidence, else: :finding
    {:ok, apply(mod, builder, [relation.name, row])}
  rescue
    e -> {:error, e}
  end

  defp modules(%{related: related} = attrs),
    do: [attrs.module | Enum.map(related, & &1.module)]

  defp modules(frame), do: [frame.module]

  # A head's template rows: a literal stays, an enumerated column takes
  # each alternative its doc declares, anything else is `:free`.
  defp expand(relation, shape) do
    relation.fields
    |> Enum.zip(shape)
    |> Enum.map(fn
      {_field, {:lit, value}} -> [value]
      {{_name, :number, _doc}, :free} -> ["3"]
      {{_name, _kind, doc}, :free} -> alternatives(doc) || [:free]
    end)
    |> cartesian()
  end

  defp cartesian([]), do: [[]]
  defp cartesian([values | rest]), do: for(v <- values, tail <- cartesian(rest), do: [v | tail])

  # A doc that opens with "rescue | erpc_transport | rpc" declares the
  # values a column takes (the prose after them says when); a doc in
  # prose does not.
  defp alternatives(doc) do
    case Regex.run(~r/^[a-z_]+(?: \| [a-z_]+)+(?=$|[ ,;])/, doc) do
      [run] -> String.split(run, " | ")
      nil -> nil
    end
  end

  # ── Reading rule heads ──────────────────────────────────────────────

  defp heads(mod) do
    mod.rules_file()
    |> sources(@dl_root, MapSet.new())
    |> Enum.map(&heads_in/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _k, a, b -> a ++ b end))
    |> Map.new(fn {name, shapes} -> {name, Enum.uniq(shapes)} end)
  end

  defp sources(relative, dir, seen) do
    path = Path.expand(relative, dir)

    if MapSet.member?(seen, path) do
      []
    else
      text = File.read!(path)

      includes =
        for [_, inc] <- Regex.scan(~r/^\.include "([^"]+)"/m, text),
            do: sources(inc, Path.dirname(path), MapSet.put(seen, path))

      [text | List.flatten(includes)]
    end
  end

  defp heads_in(source) do
    source
    |> String.replace(~r{//[^\n]*}, "")
    |> statements()
    |> Enum.flat_map(fn statement ->
      case Regex.run(~r/^([a-z_][a-z0-9_]*)\(/, statement) do
        [prefix, name] ->
          {args, rest} =
            args(
              binary_part(statement, byte_size(prefix), byte_size(statement) - byte_size(prefix))
            )

          rest = String.trim_leading(rest)

          if String.starts_with?(rest, ":-") or rest == "" or String.starts_with?(rest, "."),
            do: [{name, args}],
            else: []

        nil ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Statements begin at column 0 (bodies are indented) and are not
  # directives.
  defp statements(source) do
    source
    |> String.split(~r/\n(?=[a-z_])/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ".")))
  end

  # The top-level arguments of a head, after its opening paren, and what
  # follows the closing one.
  defp args(text), do: args(text, 0, "", [], false)

  defp args(<<?", rest::binary>>, depth, cur, acc, false),
    do: args(rest, depth, cur <> "\"", acc, true)

  defp args(<<?", rest::binary>>, depth, cur, acc, true),
    do: args(rest, depth, cur <> "\"", acc, false)

  defp args(<<c, rest::binary>>, depth, cur, acc, true),
    do: args(rest, depth, cur <> <<c>>, acc, true)

  defp args(<<?(, rest::binary>>, depth, cur, acc, false),
    do: args(rest, depth + 1, cur <> "(", acc, false)

  defp args(<<?), rest::binary>>, 0, cur, acc, false),
    do: {Enum.reverse([arg(cur) | acc]), rest}

  defp args(<<?), rest::binary>>, depth, cur, acc, false),
    do: args(rest, depth - 1, cur <> ")", acc, false)

  defp args(<<?,, rest::binary>>, 0, cur, acc, false),
    do: args(rest, 0, "", [arg(cur) | acc], false)

  defp args(<<c, rest::binary>>, depth, cur, acc, false),
    do: args(rest, depth, cur <> <<c>>, acc, false)

  defp arg(text) do
    case Regex.run(~r/^"([^"]*)"$/, String.trim(text)) do
      [_, literal] -> {:lit, literal}
      nil -> :free
    end
  end
end
