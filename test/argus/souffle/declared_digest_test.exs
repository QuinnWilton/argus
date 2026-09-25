defmodule Argus.Souffle.DeclaredDigestTest do
  @moduledoc """
  A solve is keyed on the program as it reads it
  (`Argus.Souffle.Cache.declared_digest/2`): of the generated
  declaration files, only the declarations of the relations Souffle
  loads for it. This checks that claim against the solver, for every
  shipped program over the fixtures' facts: in a copy of `priv/dl`
  whose generated files have every other declaration changed — fields
  renamed, prose rewritten, a relation added — the program loads the
  same relations and writes the same files, byte for byte, and its
  digest does not move. With those declarations' types changed and a
  field added as well, a program either does the same or no longer
  compiles, which resolving its inputs reports before any solve is
  keyed (so no kept solve stands in for the failure). And a change to
  a declaration it loads moves its digest.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Souffle.Cache

  @moduletag :tmp_dir

  @generated ~w(base.dl layer2.dl priors.dl)

  setup_all do
    modules =
      for mod <- Application.spec(:panoptes, :modules),
          String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Test.Fixtures."),
          do: mod

    {:ok, analyses} = Argus.Analysis.set(:all)
    opts = [cache: Argus.Test.Memo.store()]
    {:ok, facts} = Argus.Analysis.extract_facts(modules, analyses ++ [:coverage], opts)
    on_exit(fn -> File.rm_rf!(Path.dirname(facts)) end)

    dl = Path.join(:code.priv_dir(:panoptes), "dl")

    programs =
      [Path.join(dl, "stage0.dl"), Path.join(dl, "points_to.dl")] ++
        Enum.sort(Path.wildcard(Path.join(dl, "analyses/*.dl")))

    %{facts: facts, dl: dl, programs: programs}
  end

  test "the generated files hold declarations alone", %{dl: dl} do
    for file <- @generated do
      assert {:ok, [_ | _]} = Cache.declarations(File.read!(Path.join(dl, file))), file
    end
  end

  test "a declaration a program does not load moves neither its outputs nor its key",
       %{tmp_dir: tmp, facts: facts, dl: dl, programs: programs} do
    programs
    |> Task.async_stream(&check(&1, facts, dl, tmp), timeout: :infinity, max_concurrency: 4)
    |> Enum.each(fn {:ok, :ok} -> :ok end)
  end

  test "a declaration read as text is any other file: a comment that splices is not skipped" do
    assert {:ok, [{"a", ".decl a(x: symbol)\n.input a"}]} =
             Cache.declarations("// A.\n\n.decl a(x: symbol)\n.input a\n")

    for text <- [
          "// ends in a splice \\\n.decl a(x: symbol)\n.input a\n",
          "// trigraph ??/\n.decl a(x: symbol)\n.input a\n",
          ".decl a(x: symbol) brie\n.input a\n",
          ".decl a(x: symbol)\n.input a(IO=file)\n",
          ".decl a(x: symbol)\n",
          ".decl a(x: symbol)\n.input b\n",
          "a(1).\n",
          "/* block */\n.decl a(x: symbol)\n.input a\n"
        ] do
      assert Cache.declarations(text) == :error, inspect(text)
    end
  end

  test "a program a changed declaration no longer compiles fails before a solve is keyed",
       %{tmp_dir: tmp, facts: facts, dl: dl, programs: programs} do
    # A relation a rule of the program names that it does not load: a
    # rule Souffle prunes, but only after checking it (unless it lies in
    # a component the program never instantiates: those are tried in
    # turn until one breaks).
    broken =
      Enum.find_value(programs, fn program ->
        {:ok, kept} = Souffle.input_relations(program)
        relative = Path.relative_to(program, dl)

        program
        |> named()
        |> Enum.filter(&(&1 not in kept and generated?(dl, &1)))
        |> Enum.sort()
        |> Enum.find_value(fn relation ->
          root = Path.join([tmp, Path.basename(program, ".dl"), relation])
          broken = Path.join(perturb(root, dl, &(&1 == relation), &retype/1), relative)
          if match?({:error, _}, Souffle.input_relations(broken)), do: broken
        end)
      end)

    assert broken, "no declaration a program does not load breaks it: nothing to check"
    solves = Path.join(tmp, "solves")
    assert {:error, _} = Souffle.run(facts, broken, solve_cache: solves)
    assert File.ls(solves) in [{:ok, []}, {:error, :enoent}]
  end

  defp check(program, facts, dl, tmp) do
    name = Path.basename(program, ".dl")
    relative = Path.relative_to(program, dl)
    {:ok, kept} = Souffle.input_relations(program)
    {:ok, original} = solve(facts, program, Path.join([tmp, name, "original"]))
    digest = Cache.declared_digest(program, kept)

    # Renamed, reworded, one added: the program is the same program.
    renamed = perturb(Path.join([tmp, name, "renamed"]), dl, &(&1 not in kept), &rename/1)
    renamed_program = Path.join(renamed, relative)

    assert Cache.declared_digest(renamed_program, kept) == digest, name
    refute Cache.declared_digest(renamed_program, :all) == Cache.declared_digest(program, :all)
    assert {:ok, ^kept} = Souffle.input_relations(renamed_program)
    assert {:ok, ^original} = solve(facts, renamed_program, Path.join([tmp, name, "out_r"])), name

    # Retyped too, and widened, where no rule names them: the same.
    named = named(program)
    retype? = &(&1 not in kept and &1 not in named)

    retyped =
      perturb(Path.join([tmp, name, "retyped"]), dl, retype?, &(&1 |> rename() |> retype()))

    retyped_program = Path.join(retyped, relative)
    assert Cache.declared_digest(retyped_program, kept) == digest, name
    assert {:ok, ^kept} = Souffle.input_relations(retyped_program)
    assert {:ok, ^original} = solve(facts, retyped_program, Path.join([tmp, name, "out_t"])), name

    # A declaration it loads moves its key.
    if loaded = Enum.find(kept, &generated?(dl, &1)) do
      moved = perturb(Path.join([tmp, name, "moved"]), dl, &(&1 == loaded), &rename/1)
      refute Cache.declared_digest(Path.join(moved, relative), kept) == digest, name
    end

    :ok
  end

  defp generated?(dl, relation) do
    Enum.any?(@generated, fn file ->
      {:ok, blocks} = Cache.declarations(File.read!(Path.join(dl, file)))
      List.keymember?(blocks, relation, 0)
    end)
  end

  # The files a solve writes, by name.
  defp solve(facts, program, out) do
    File.mkdir_p!(out)

    with {:ok, _results} <- Souffle.run(facts, program, output_dir: out) do
      {:ok, Map.new(File.ls!(out), &{&1, File.read!(Path.join(out, &1))})}
    end
  end

  # The relations a program's own rules name (its files other than the
  # generated ones, without their comments).
  defp named(program) do
    for {_spelled, file} <- Cache.program_files(program),
        Path.basename(file) not in @generated,
        code = file |> File.read!() |> String.replace(~r{/\*.*?\*/|//[^\n]*}s, ""),
        [_, relation] <- Regex.scan(~r/\b([a-z_][a-z0-9_]*)\s*\(/, code),
        into: MapSet.new(),
        do: relation
  end

  # A copy of `dl` whose generated files have each declaration of a
  # relation `change?` picks changed by `change`, their prose rewritten,
  # and a relation added.
  defp perturb(root, dl, change?, change) do
    File.mkdir_p!(Path.dirname(root))
    File.cp_r!(dl, root)

    for file <- @generated do
      path = Path.join(root, file)
      {:ok, blocks} = Cache.declarations(File.read!(path))

      body =
        Enum.map_join(blocks, "\n", fn {relation, block} ->
          [decl, input] = String.split(block, "\n")
          decl = if change?.(relation), do: change.(decl), else: decl
          "// Perturbed prose for #{relation}.\n//\n#{decl}\n#{input}\n"
        end)

      probe = "probe_#{Path.rootname(file)}"

      File.write!(
        path,
        "// Perturbed header.\n\n#{body}\n// A relation no program reads.\n" <>
          ".decl #{probe}(x: symbol)\n.input #{probe}\n"
      )
    end

    root
  end

  defp rename(decl) do
    [_, name, fields] = Regex.run(~r/^\.decl (\w+)\((.*)\)$/, decl)

    fields =
      fields
      |> String.split(", ", trim: true)
      |> Enum.map_join(", ", fn field ->
        [field, type] = String.split(field, ": ")
        "#{field}_p: #{type}"
      end)

    ".decl #{name}(#{fields})"
  end

  defp retype(decl) do
    [_, name, fields] = Regex.run(~r/^\.decl (\w+)\((.*)\)$/, decl)

    fields =
      fields
      |> String.split(", ", trim: true)
      |> Enum.map(fn field ->
        case String.split(field, ": ") do
          [f, "symbol"] -> "#{f}: number"
          [f, "number"] -> "#{f}: symbol"
        end
      end)

    ".decl #{name}(#{Enum.join(fields ++ ["widened: number"], ", ")})"
  end
end
