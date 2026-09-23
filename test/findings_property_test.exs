defmodule Argus.FindingsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Findings
  alias Argus.InstrId

  # ── Generators ──────────────────────────────────────────────────────

  defp segment do
    gen all(
          head <- string(?A..?Z, length: 1),
          tail <- string([?a..?z, ?A..?Z, ?0..?9, ?_], max_length: 6)
        ) do
      head <> tail
    end
  end

  defp elixir_module do
    gen all(segments <- list_of(segment(), min_length: 1, max_length: 3)) do
      Module.concat(segments)
    end
  end

  defp erlang_module do
    gen all(
          head <- string(?a..?z, length: 1),
          tail <- string([?a..?z, ?0..?9, ?_], max_length: 8)
        ) do
      String.to_atom(head <> tail)
    end
  end

  defp module_name, do: one_of([elixir_module(), erlang_module()])

  defp function_name do
    one_of([
      map(string(?a..?z, min_length: 1, max_length: 8), &String.to_atom/1),
      # Compiler-generated closure names carry `/` and `-`.
      constant(:"-run/2-fun-0-")
    ])
  end

  # Anything a row's column can hold: IDs of both precisions, modules,
  # placeholders, and noise.
  defp column_value do
    one_of([
      gen all(m <- module_name(), f <- function_name(), a <- integer(0..5)) do
        InstrId.func_id(m, f, a)
      end,
      gen all(m <- module_name(), f <- function_name(), a <- integer(0..5), i <- integer(0..40)) do
        InstrId.mint(InstrId.func_id(m, f, a), i)
      end,
      map(module_name(), &inspect/1),
      member_of(["", "dynamic", ":", "via:Registry"]),
      string(:printable, max_length: 20)
    ])
  end

  defp modules_of(anchor) do
    [anchor.module | if(anchor.mfa, do: [elem(anchor.mfa, 0)], else: [])]
  end

  defp assert_no_invented_module(anchor) do
    for module <- modules_of(anchor), module != nil do
      name = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
      refute String.contains?(name, [":", "/"]), "invented module #{inspect(module)}"
    end
  end

  # ── Anchors ─────────────────────────────────────────────────────────

  describe "module_atom/1 and the at_* anchors" do
    property "module_atom round-trips every inspect rendering" do
      check all(module <- module_name()) do
        assert Findings.module_atom(inspect(module)) == module
      end
    end

    property "no anchor invents a module whose name holds : or /" do
      check all(a <- column_value(), b <- column_value(), c <- column_value()) do
        assert_no_invented_module(Findings.at_module(a))
        assert_no_invented_module(Findings.at_mfa(a, :init, 1))
        assert_no_invented_module(Findings.at_func(a))
        assert_no_invented_module(Findings.at_instr(a))
        assert_no_invented_module(Findings.at_site(a, b))
        assert_no_invented_module(Findings.at_site_in_func(a, b))
        assert_no_invented_module(Findings.at_site_in_func(a, b, c))
      end
    end

    property "at_func and at_instr round-trip through the ID wire format" do
      check all(m <- module_name(), f <- function_name(), a <- integer(0..5), i <- integer(0..40)) do
        func_id = InstrId.func_id(m, f, a)
        assert %{module: ^m, mfa: {^m, ^f, ^a}, instr: nil} = Findings.at_func(func_id)

        anchor = Findings.at_instr(InstrId.mint(func_id, i))
        assert anchor.mfa == {m, f, a}
        assert InstrId.format(anchor.instr) == InstrId.mint(func_id, i)
      end
    end

    property "at_site_in_func falls back to the function, never to a module named after it" do
      check all(
              m <- module_name(),
              f <- function_name(),
              a <- integer(0..5),
              site <- member_of(["", "dynamic", "not an id"])
            ) do
        func_id = InstrId.func_id(m, f, a)
        assert Findings.at_site_in_func(site, func_id) == Findings.at_func(func_id)
        # The module-string form is for module strings: handed a function
        # ID it anchors nowhere rather than at an invented module.
        assert %{module: nil, mfa: nil, instr: nil} = Findings.at_site(site, func_id)
      end
    end
  end

  # ── dedupe_rows/2 ───────────────────────────────────────────────────

  @fields [{:mod, :symbol, "m"}, {:kind, :symbol, "k"}, {:site, :symbol, "s"}]

  defp keyed_relation do
    one_of([
      map(member_of([[:mod], [:mod, :kind], [:kind, :site], [:mod, :kind, :site]]), fn key ->
        %{name: :r, fields: @fields, key: key}
      end),
      # A key chosen by the kind column; "c" is unnamed, so it takes the
      # default when there is one and every column when there is not.
      map(boolean(), fn default? ->
        keys = %{"a" => [:mod], "b" => [:mod, :site]}
        keys = if default?, do: Map.put(keys, :default, [:kind]), else: keys
        %{name: :r, fields: @fields, key: {:kind, keys}}
      end)
    ])
  end

  defp rows do
    list_of(
      fixed_list([member_of(["M", "N"]), member_of(["a", "b", "c"]), member_of(["1", "2", "3"])]),
      max_length: 20
    )
  end

  # The identity a row is deduplicated under, computed independently of
  # the implementation from the relation's declared key.
  defp identity(%{key: key}, row) when is_list(key), do: Enum.map(key, &column(row, &1))

  defp identity(%{key: {:kind, keys}}, [_, kind, _] = row) do
    columns = Map.get(keys, kind) || Map.get(keys, :default, [:mod, :kind, :site])
    {kind, Enum.map(columns, &column(row, &1))}
  end

  defp column([m, _, _], :mod), do: m
  defp column([_, k, _], :kind), do: k
  defp column([_, _, s], :site), do: s

  describe "dedupe_rows/2" do
    property "keeps exactly the least row of each identity, sorted" do
      check all(relation <- keyed_relation(), rows <- rows()) do
        expected =
          rows
          |> Enum.group_by(&identity(relation, &1))
          |> Enum.map(fn {_identity, group} -> Enum.min(group) end)
          |> Enum.sort()

        assert Findings.dedupe_rows(relation, rows) == expected
      end
    end

    property "is idempotent, order-invariant and never grows" do
      check all(relation <- keyed_relation(), rows <- rows(), seed <- integer()) do
        once = Findings.dedupe_rows(relation, rows)
        :rand.seed(:exsss, {seed, seed, seed})

        assert Findings.dedupe_rows(relation, once) == once
        assert Findings.dedupe_rows(relation, Enum.shuffle(rows)) == once
        assert length(once) <= length(rows)
        assert Enum.all?(once, &(&1 in rows))
      end
    end

    property "a relation without a key passes its rows through" do
      check all(rows <- rows()) do
        assert Findings.dedupe_rows(%{name: :r, fields: @fields}, rows) == rows
      end
    end
  end
end
