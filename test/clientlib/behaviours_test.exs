defmodule Argus.Clientlib.BehavioursTest do
  @moduledoc """
  Guards the canonicalisation of behaviour names across the two languages.

  `implements_behaviour` stores what the module declared, rendered with
  `inspect/1`: `@behaviour GenServer` becomes `"GenServer"` and
  `-behaviour(gen_server)` becomes `":gen_server"`, colon and all. A rule
  matching the Elixir spelling sees only the Elixir half, and returns fewer
  findings rather than an error — which is indistinguishable from cleaner
  code, and is why this went unnoticed until a Datalog result was compared
  against the extractor output feeding it.
  """

  use ExUnit.Case

  alias Argus.Souffle

  @canonical_dl "clientlib/behaviours.dl"

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "every rule asks the canonical question" do
    # Static, so it holds without Souffle and without a corpus.
    test "no rule matches a declared behaviour string directly" do
      offenders =
        priv_dl()
        |> Path.join("{analyses,clientlib}/*.dl")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) == "behaviours.dl"))
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim(line), "//") end)
          |> Enum.filter(fn {line, _} -> line =~ ~r/implements_behaviour\(\w+,\s*"/ end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(path, priv_dl())}:#{n}  #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             "these rules match a declared behaviour name and so see only " <>
               "Elixir modules:\n" <>
               Enum.join(offenders, "\n") <>
               "\n\nUse behaves_as/2 from #{@canonical_dl} instead."
    end

    test "no rule asks behaves_as for a name the alias table rewrites" do
      # The subtle half. `behaves_as` passes unaliased names through
      # unchanged, so asking for a name nobody listed still works — but
      # asking for one that IS aliased silently derives nothing, because
      # the alias maps it away. Two rules matched ":gen_statem" this way
      # and stopped matching anything the moment the indirection landed.
      aliased =
        priv_dl()
        |> Path.join(@canonical_dl)
        |> File.read!()
        |> then(&Regex.scan(~r/behaviour_alias\("([^"]+)",\s*"([^"]+)"\)/, &1))
        |> Enum.reject(fn [_, declared, canonical] -> declared == canonical end)
        |> Enum.map(fn [_, declared, _] -> declared end)
        |> MapSet.new()

      offenders =
        priv_dl()
        |> Path.join("{analyses,clientlib}/*.dl")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) == "behaviours.dl"))
        |> Enum.flat_map(fn path ->
          ~r/behaves_as\(\w+,\s*"([^"]+)"\)/
          |> Regex.scan(File.read!(path))
          |> Enum.filter(fn [_, name] -> MapSet.member?(aliased, name) end)
          |> Enum.map(fn [_, name] ->
            "#{Path.basename(path)}: behaves_as(_, #{inspect(name)})"
          end)
        end)

      assert offenders == [],
             "these ask for a spelling the alias table rewrites, so they " <>
               "derive nothing:\n" <>
               Enum.join(offenders, "\n") <>
               "\n\nAsk for the canonical name instead."
    end

    test "every analysis using behaves_as includes the file defining it" do
      offenders =
        priv_dl()
        |> Path.join("analyses/*.dl")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          src = File.read!(path)
          src =~ ~r/behaves_as\(/ and not String.contains?(src, @canonical_dl <> "\"")
        end)
        |> Enum.map(&Path.basename/1)

      assert offenders == [], "missing the behaviours.dl include: #{inspect(offenders)}"
    end
  end

  describe "canonicalisation" do
    @tag :souffle
    @tag :tmp_dir
    test "both spellings of gen_server reach the same canonical name", %{tmp_dir: tmp_dir} do
      unless Souffle.available?(), do: flunk("souffle not installed")

      facts_dir = Path.join(tmp_dir, "facts")
      File.mkdir_p!(facts_dir)

      File.write!(
        Path.join(facts_dir, "implements_behaviour.facts"),
        """
        Elixir.A\tGenServer
        :b\t:gen_server
        :c\tsupervisor
        Elixir.D\tSome.Unlisted.Behaviour
        """
      )

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/behaviours.dl")}"
      .output behaves_as
      """

      rules_path = Path.join(tmp_dir, "beh.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)
      rows = Map.get(results, "behaves_as", [])

      assert ["Elixir.A", "GenServer"] in rows
      assert [":b", "GenServer"] in rows, "the Erlang spelling must canonicalise"
      assert [":c", "Supervisor"] in rows, "the bare Erlang spelling too"

      assert ["Elixir.D", "Some.Unlisted.Behaviour"] in rows,
             "a behaviour nobody listed must pass through, or the " <>
               "indirection turns into a fresh source of under-reporting"
    end
  end
end
