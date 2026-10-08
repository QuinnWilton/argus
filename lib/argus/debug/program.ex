defmodule Argus.Debug.Program do
  @moduledoc false

  alias Argus.Dl.Program

  # Copy the shipped tree with familiar paths. Custom programs keep their include
  # closure in a separate directory, with rewritten relative includes so a bundle
  # remains runnable after the original checkout or custom source is removed.
  @spec copy!(Path.t(), Path.t()) :: Path.t()
  def copy!(path, destination) do
    root = Path.expand(Argus.Dl.root())
    # Past the file server: a hundred files a capture, and again each run.
    Argus.RawFile.cp_r!(root, Path.join(destination, "rules"))

    if String.starts_with?(Path.expand(path), root <> "/") do
      "rules/" <> Path.relative_to(path, root)
    else
      copy_custom!(path, destination)
    end
  end

  defp copy_custom!(path, destination) do
    files = Program.program_files(path)

    names =
      files
      |> Enum.with_index()
      |> Map.new(fn {{_, file}, i} -> {file, "#{i}-#{Path.basename(file)}"} end)

    dir = Path.join(destination, "rules/custom")
    File.mkdir_p!(dir)

    for {_, file} <- files do
      content =
        Regex.replace(~r/^(\s*[.#]include\s+)"([^"]+)"/m, File.read!(file), fn _,
                                                                               directive,
                                                                               ref ->
          included = Path.expand(ref, Path.dirname(file))
          directive <> JSON.encode!(Map.fetch!(names, included))
        end)

      File.write!(Path.join(dir, Map.fetch!(names, file)), content)
    end

    "rules/custom/" <> Map.fetch!(names, Path.expand(path))
  end

  @spec wrapper!(Path.t(), Path.t(), Path.t(), [String.t()]) :: Path.t()
  def wrapper!(root, program, run, probes) do
    source = Path.join(root, program)
    files = Program.program_files(source)

    existing =
      for {_, file} <- files,
          [_, name] <- Regex.scan(~r/^\s*\.output\s+([\w.]+)/m, File.read!(file)),
          do: name

    for name <- probes do
      unless Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/, name) do
        raise ArgumentError, "invalid relation name #{inspect(name)}"
      end
    end

    outputs = for name <- Enum.uniq(probes) -- existing, do: ".output #{name}\n"
    path = Path.join(run, "program.dl")
    include = run_copy!(root, program, run, probes)
    File.write!(path, [".include ", JSON.encode!(include), "\n", outputs])
    path
  end

  defp run_copy!(root, program, run, _probes) do
    Argus.RawFile.cp_r!(Path.join(root, "rules"), Path.join(run, "rules"))
    program
  end

  # FlowLog expands components and resolves types; the tool reports every
  # relation's columns after it has (`Argus.FlowLog.manifest/2`). Source
  # matching below is only navigation; it never determines a production
  # dependency or cache key.
  @spec columns!(Path.t(), Path.t(), Path.t()) :: %{String.t() => [map()]}
  def columns!(path, run, snapshot \\ "program.relations.json") do
    case Argus.FlowLog.manifest(path) do
      {:ok, %{relations: relations}} ->
        File.write!(Path.join(run, snapshot), JSON.encode!(relations))
        Map.new(relations, &{&1.name, &1.columns})

      {:error, reason} ->
        raise ArgumentError,
              "FlowLog could not compile the debug program:\n" <>
                Argus.FlowLog.describe_error(reason) <>
                "\nA probe must name a relation whose columns are symbols or numbers."
    end
  end

  @spec sources(Path.t(), Path.t(), String.t()) ::
          [%{path: Path.t(), line: pos_integer(), text: String.t()}]
  def sources(root, program, name) do
    # A qualified relation also leads to the component instantiation. Its class
    # leads to the reusable definition, even when the declaration is inherited.
    programs =
      cond do
        name in Argus.Analysis.stage0_relations() ->
          [program, "rules/stage0.dl"]

        name in Argus.Analysis.points_to_relations() ->
          [program, "rules/points_to.dl", "rules/points_to_bounded.dl"]

        true ->
          [program]
      end

    files =
      programs
      |> Enum.flat_map(&Program.program_files(Path.join(root, &1)))
      |> Enum.uniq_by(&elem(&1, 1))

    [instance | _] = String.split(name, ".")

    classes =
      for {_, file} <- files,
          [_, class] <-
            Regex.scan(~r/\.init\s+#{Regex.escape(instance)}\s*=\s*([\w]+)/, File.read!(file)),
          do: class

    names = Enum.uniq([name, instance | classes])

    pattern =
      Regex.compile!("(?<![\\w.])(?:#{Enum.map_join(names, "|", &Regex.escape/1)})(?![\\w.])")

    for {_, file} <- files,
        {line, index} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(pattern, line),
        do: %{path: Path.relative_to(file, root), line: index, text: String.trim(line)}
  end
end
