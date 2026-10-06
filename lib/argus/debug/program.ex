defmodule Argus.Debug.Program do
  @moduledoc false

  alias Argus.Souffle.Program

  # Copy the shipped tree with familiar paths. Custom programs keep their include
  # closure in a separate directory, with rewritten relative includes so a bundle
  # remains runnable after the original checkout or custom source is removed.
  @spec copy!(Path.t(), Path.t()) :: Path.t()
  def copy!(path, destination) do
    root = Path.expand(Argus.Dl.root())
    File.cp_r!(root, Path.join(destination, "rules"))

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

  defp run_copy!(root, program, run, probes) do
    File.cp_r!(Path.join(root, "rules"), Path.join(run, "rules"))

    # Materialize only requested predicates in this run's private copy. Other
    # inline definitions may rely on variables supplied by their callers and
    # must stay inline. Caller-bound predicates need a grounded consumer probe.
    requested = MapSet.new(probes, fn name -> name |> String.split(".") |> List.last() end)

    for path <- Path.wildcard(Path.join(run, "rules/**/*.dl")), probes != [] do
      content =
        Regex.replace(~r/^(\s*\.decl\s+([\w.]+)\s*\([^)]*\))([^\n]*)/m, File.read!(path), fn _,
                                                                                             declaration,
                                                                                             name,
                                                                                             qualifiers ->
          qualifiers =
            if MapSet.member?(requested, name),
              do: Regex.replace(~r/\binline\b/, qualifiers, ""),
              else: qualifiers

          declaration <> qualifiers
        end)

      File.write!(path, content)
    end

    program
  end

  # The solver expands components and resolves types. Source matching below is
  # only navigation; it never determines a production dependency or cache key.
  @spec columns!(Path.t(), Path.t(), Path.t(), Path.t()) :: %{String.t() => [map()]}
  def columns!(bin, path, run, snapshot \\ "program.ast") do
    args = ["--show=transformed-ast", "--wno=all", path]

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {ast, 0} ->
        File.write!(Path.join(run, snapshot), ast)

        ~r/^\.decl\s+([\w.]+)\s*\(([^)]*)\)/m
        |> Regex.scan(ast)
        |> Map.new(fn [_, name, fields] ->
          columns =
            for field <- String.split(fields, ",", trim: true) do
              [column, type] = String.split(field, ":", parts: 2)
              %{"name" => String.trim(column), "type" => String.trim(type)}
            end

          {name, columns}
        end)

      {message, status} ->
        raise ArgumentError,
              "Soufflé could not compile the debug program (#{status}):\n#{message}\n" <>
                "Inline predicates that depend on caller-bound variables cannot be " <>
                "enumerated independently; probe a grounded consumer instead."
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
