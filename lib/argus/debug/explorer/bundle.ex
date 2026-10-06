defmodule Argus.Debug.Explorer.Bundle do
  @moduledoc false

  alias Argus.Debug

  # Read only debug bundles. No Roux cache or analyzed BEAM is loaded here.
  @spec load!(Path.t(), Path.t() | nil) :: map()
  def load!(root, run \\ nil) do
    root = Path.expand(root)
    manifest = Debug.manifest!(root)
    snapshot = Debug.snapshot!(root, run: run)
    available = MapSet.new(Debug.relations!(root, run: run))
    outputs = MapSet.new(snapshot["outputs"] || [])

    names =
      Enum.uniq(
        MapSet.to_list(available) ++
          Map.keys(manifest["schema"] || %{}) ++
          Map.keys(snapshot["columns"] || %{})
      )

    relations =
      for name <- names, not String.starts_with?(name, "__") do
        kind =
          cond do
            MapSet.member?(outputs, name) ->
              "output"

            MapSet.member?(available, name) or Map.has_key?(manifest["schema"] || %{}, name) ->
              "fact"

            true ->
              "intermediate"
          end

        %{name: name, kind: kind, available?: MapSet.member?(available, name)}
      end
      |> Enum.sort_by(&{rank(&1.kind), &1.name})

    %{
      root: root,
      manifest: manifest,
      snapshot: snapshot,
      run: run,
      relations: relations,
      runs: Debug.runs!(root)
    }
  end

  @spec search(map(), String.t()) :: [map()]
  def search(bundle, query) do
    query = String.downcase(query)
    Enum.filter(bundle.relations, &String.contains?(String.downcase(&1.name), query))
  end

  @spec relation!(map(), String.t(), String.t(), non_neg_integer(), pos_integer()) :: map()
  def relation!(bundle, name, filter, page, page_size) do
    opts = [run: bundle.run]
    description = Debug.describe!(bundle.root, name, opts)
    where = filter!(filter)

    table =
      Debug.rows!(bundle.root, name,
        run: bundle.run,
        where: where,
        offset: page * page_size,
        limit: page_size
      )

    %{description: description, table: table, page: page}
  end

  @spec filter!(String.t()) :: [{String.t(), String.t()}]
  def filter!(""), do: []

  def filter!(filter) do
    case String.split(filter, "=", parts: 2) do
      [column, value] when column != "" -> [{column, value}]
      _ -> raise ArgumentError, "Use column=value, for example kind=never_runs"
    end
  end

  @spec overview(map()) :: String.t()
  def overview(bundle) do
    manifest = bundle.manifest

    [
      "Analysis: #{manifest["analysis"] || "custom program"}",
      "Program: #{manifest["program"]}",
      "Solver: #{manifest["solver"]}",
      "Priors: #{manifest["priors"]}",
      "Run: #{bundle.snapshot["directory"] || "no successful solve"}",
      "Probes: #{Enum.join(bundle.snapshot["probes"] || [], ", ")}",
      "",
      "Captured application sources",
      entries(manifest["sources"] || %{}),
      "",
      "Relation producers",
      for {relation, producers} <- Enum.sort(manifest["producers"] || %{}) do
        "#{relation}: " <> Enum.map_join(producers, ", ", & &1["module"])
      end,
      "",
      "Rows are static analysis evidence; rule references are not derivation proofs."
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> text()
  end

  @spec unavailable(map(), String.t() | nil, String.t() | nil) :: String.t()
  def unavailable(bundle, name, error) do
    relation = Enum.find(bundle.relations, &(&1.name == name))

    if relation && relation.kind == "intermediate" do
      "This relation has a definition, but no saved rows.\n\n" <>
        "Expose it from another terminal:\n\n" <>
        "mix argus.debug solve #{quote_arg(bundle.root)} --probe #{quote_arg(name)}\n\n" <>
        "Then press R to follow the latest solve."
    else
      error || "No relation selected. Search with / or choose a relation from the list."
    end
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @spec details(map()) :: String.t()
  def details(description) do
    [
      description.doc || "No captured description.",
      "",
      "Columns",
      for field <- description.fields do
        "#{field["name"]}: #{field["type"]}  #{field["doc"]}"
      end,
      "",
      "Producers",
      for producer <- description.producers do
        "#{producer["module"]}\n  #{producer["file"] || "source unavailable"}"
      end
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> text()
  end

  @spec source!(Path.t() | nil, pos_integer() | nil) :: map()
  def source!(path, line) do
    unless is_binary(path), do: raise(ArgumentError, "Source path was not captured")
    line = line || 1
    start = max(line - 8, 1)

    lines = path |> File.stream!() |> Stream.drop(start - 1) |> Enum.take(200)

    content =
      for {content, number} <- Enum.with_index(lines, start) do
        "#{if number == line, do: ">", else: " "} #{number}  #{String.trim_trailing(content)}"
      end

    %{
      title: text("#{path}:#{line}"),
      content: text(Enum.join(content, "\n")),
      note: "Source excerpt: up to 200 lines. Escape returns to exploration."
    }
  end

  @spec location!(map(), String.t()) :: map()
  def location!(bundle, value) do
    location = Debug.locate!(bundle.root, value)

    if location.line == nil,
      do: raise(ArgumentError, "No captured source line for #{value}")

    source!(location.file, location.line)
  end

  @spec id?(String.t()) :: boolean()
  def id?(value) do
    match?({:ok, _}, Argus.InstrId.parse(value)) or
      match?({:ok, _}, Argus.InstrId.parse_func(value))
  end

  @spec wrap(String.t(), integer()) :: String.t()
  def wrap(content, width) do
    content
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      line
      |> String.graphemes()
      |> Enum.chunk_every(max(width, 1))
      |> Enum.map_join("\n", &Enum.join/1)
    end)
  end

  # Captured values and source files may contain terminal control characters.
  @spec text(String.Chars.t()) :: String.t()
  def text(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x{9F}]/u, "�")
    |> String.replace("\t", "    ")
  end

  defp entries(map),
    do: Enum.map(Enum.sort(map), fn {key, value} -> "#{key}: #{value || "unavailable"}" end)

  defp rank("output"), do: 0
  defp rank("fact"), do: 1
  defp rank("intermediate"), do: 2
end
