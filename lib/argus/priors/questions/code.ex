defmodule Argus.Priors.Questions.Code do
  @moduledoc """
  The names a question shows the model about a program's functions: what
  each calls, the literals it holds, who calls it, and how a reader
  spells it.

  A question hands the model names only — modules, functions, literals —
  never instruction ids, labels or lines, which it reads as noise. The
  index here is built once per question from the typed facts and read
  by each subject's state. A closure's calls and literals count as its
  parent's, the way a reader sees `Enum.map(xs, &Repo.get/1)` as one
  function reading storage, and a closure holding the subject is shown
  as the function it is written in.
  """

  alias Argus.InstrId

  @typedoc "What the index knows of one function."
  @type func :: %{
          mod: String.t(),
          name: String.t(),
          arity: non_neg_integer(),
          exported: boolean()
        }

  @type t :: %{
          funcs: %{String.t() => func()},
          by_mod: %{String.t() => [String.t()]},
          behaviours: %{String.t() => [String.t()]},
          callees: %{String.t() => [String.t()]},
          callers: %{String.t() => [String.t()]},
          closures: %{String.t() => [String.t()]},
          literals: %{String.t() => [String.t()]}
        }

  @noise_erlang ~w(get_module_info error raise throw exit make_fun apply element setelement
                   tuple_size byte_size bit_size hd tl length map_size self node put get erase
                   is_atom is_binary is_list is_map is_tuple is_integer is_float is_function is_pid
                   integer_to_binary binary_to_integer atom_to_binary binary_to_list list_to_binary
                   iolist_to_binary abs rem div trunc round max min function_exported module_loaded)
  @noise_modules ~w(Kernel Kernel.Utils :maps :lists Access)

  @doc "The relations `index/1` reads."
  @spec relations_read() :: [atom()]
  def relations_read,
    do: ~w(function_def remote_call bif_call local_call closure_def literal_value tuple_literal
           implements_behaviour)a

  @doc "The index of `facts`' functions."
  @spec index(Argus.Facts.t()) :: t()
  def index(facts) do
    rows = &Map.get(facts, &1, [])

    funcs =
      Map.new(rows.(:function_def), fn r ->
        {r.func, %{mod: r.mod, name: r.name, arity: r.arity, exported: r.exported == 1}}
      end)

    edges =
      Enum.map(rows.(:remote_call), &{&1.caller, "#{&1.mod}:#{&1.func}/#{&1.arity}"}) ++
        Enum.map(rows.(:bif_call), &{&1.caller, "#{&1.mod}:#{&1.func}/#{&1.arity}"}) ++
        for(r <- rows.(:local_call), Map.has_key?(funcs, r.target), do: {r.caller, r.target})

    literals =
      Enum.map(rows.(:literal_value), &{func_of(&1.id), &1.val}) ++
        Enum.map(rows.(:tuple_literal), &{func_of(&1.id), &1.tag})

    %{
      funcs: funcs,
      by_mod: group(Map.to_list(funcs), fn {_, m} -> m.mod end, fn {id, _} -> id end),
      behaviours: group(rows.(:implements_behaviour), & &1.mod, & &1.behaviour),
      callees: group(edges, &elem(&1, 0), &elem(&1, 1)),
      callers: group(edges, &elem(&1, 1), &elem(&1, 0)),
      closures: group(rows.(:closure_def), & &1.parent_func, & &1.closure_func),
      literals: group(literals, &elem(&1, 0), &elem(&1, 1))
    }
  end

  defp group(rows, key, value) do
    rows |> Enum.group_by(key, value) |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  @doc """
  What `func` calls, its closures' calls included and the closures
  themselves elided, as a reader spells them (`Mod.fun/1`), without the
  runtime's plumbing; at most `limit`.
  """
  @spec calls(t(), String.t(), pos_integer()) :: [String.t()]
  def calls(index, func, limit) do
    index
    |> walk_calls([func], MapSet.new([func]), [])
    |> Enum.reject(&noise_call?/1)
    |> Enum.map(&pretty/1)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  defp walk_calls(_index, [], _seen, acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp walk_calls(index, [f | rest], seen, acc) do
    {closure_calls, real} = index.callees |> Map.get(f, []) |> Enum.split_with(&closure?/1)

    new =
      (closure_calls ++ Map.get(index.closures, f, [])) |> Enum.reject(&MapSet.member?(seen, &1))

    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    walk_calls(index, rest ++ new, seen, Enum.reverse(real) ++ acc)
  end

  @doc "The literals `func` and its closures hold, without the compiler's; at most `limit`."
  @spec literals(t(), String.t(), pos_integer()) :: [String.t()]
  def literals(index, func, limit) do
    mod = index.funcs |> Map.get(func, %{}) |> Map.get(:mod)
    children = Map.get(index.closures, func, [])

    [func | children]
    |> Enum.flat_map(&Map.get(index.literals, &1, []))
    |> Enum.uniq()
    |> Enum.reject(&noise_literal?(&1, mod))
    |> Enum.take(limit)
  end

  @doc """
  The functions that call `func` — for a closure, those that call the
  function it is written in — as a reader spells them; at most `limit`.
  """
  @spec callers(t(), String.t(), pos_integer()) :: [String.t()]
  def callers(index, func, limit) do
    func
    |> named()
    |> then(&Map.get(index.callers, &1, []))
    |> Enum.map(&named/1)
    |> Enum.reject(&(&1 == named(func)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&pretty/1)
    |> Enum.take(limit)
  end

  @doc """
  A function as a reader names it within its module: `name/arity`, or
  for a closure, `a fun in name/arity`.
  """
  @spec display(String.t()) :: String.t()
  def display(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{func: f, arity: a}} ->
        case parent(f) do
          {:ok, parent} -> "a fun in #{parent}"
          :error -> "#{f}/#{a}"
        end

      :error ->
        func_id
    end
  end

  # The function a closure is written in, as its id: `-keys/1-fun-0-`
  # and `-decode/1-lc$^0/1-0-` are keys/1's and decode/1's.
  defp named(func_id) do
    with {:ok, %{module: m, func: f}} <- InstrId.parse_func(func_id),
         {:ok, parent} <- parent(f) do
      "#{m}:#{parent}"
    else
      _ -> func_id
    end
  end

  defp parent(name) do
    case Regex.run(~r/^-(.+)\/(\d+)-(?:fun|lc|lbc|mc|after)/, name) do
      [_, parent, arity] -> {:ok, "#{parent}/#{arity}"}
      _ -> :error
    end
  end

  @doc "The module's own functions a reader would name, sorted; at most `limit`."
  @spec siblings(t(), String.t(), pos_integer()) :: [String.t()]
  def siblings(index, mod, limit) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.reject(&generated?(index.funcs[&1]))
    |> Enum.filter(&index.funcs[&1].exported)
    |> Enum.map(&"#{index.funcs[&1].name}/#{index.funcs[&1].arity}")
    |> Enum.sort()
    |> Enum.take(limit)
  end

  @doc "Whether a function is the compiler's rather than the author's."
  @spec generated?(func() | nil) :: boolean()
  def generated?(nil), do: true

  def generated?(%{name: name}) do
    String.starts_with?(name, "-") or String.starts_with?(name, "__") or
      String.starts_with?(name, "MACRO-") or name == "module_info" or
      String.contains?(name, "(overridable")
  end

  @doc "Whether a function ID names a closure or a comprehension's body."
  @spec closure?(String.t()) :: boolean()
  def closure?(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{func: f}} -> String.starts_with?(f, "-") and parent(f) != :error
      :error -> false
    end
  end

  @doc "A function ID as a reader writes the call: `Mod.fun/1`."
  @spec pretty(String.t()) :: String.t()
  def pretty(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{module: m, func: f, arity: a}} -> "#{m}.#{f}/#{a}"
      :error -> func_id
    end
  end

  defp noise_call?(call) do
    case InstrId.parse_func(call) do
      {:ok, %{module: ":erlang", func: f}} -> f in @noise_erlang
      {:ok, %{module: m}} -> String.starts_with?(m, ":elixir") or m in @noise_modules
      :error -> true
    end
  end

  defp noise_literal?(val, mod) do
    val in [
      "nil",
      "true",
      "false",
      "[]",
      "%{}",
      mod,
      ":ok",
      ":error",
      ":__block__",
      ":__aliases__"
    ] or
      String.starts_with?(val, "#") or String.starts_with?(val, "<<") or byte_size(val) > 48
  end

  defp func_of(%InstrId{module: m, func: f, arity: a}), do: "#{m}:#{f}/#{a}"

  defp func_of(s) when is_binary(s) do
    case InstrId.func_id_of(s) do
      {:ok, id} -> id
      :error -> s
    end
  end
end
