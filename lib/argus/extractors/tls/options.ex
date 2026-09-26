defmodule Argus.Extractors.Tls.Options do
  @moduledoc """
  The option list a call is handed, as far as the function builds it: its
  keys and where each literal in it came from.

  A server's `verify: :verify_none` asks its clients for no certificate
  (`Argus.Extractors.Tls`), but only when it is a TLS option of the
  server's: the options themselves (`:ssl.listen/2`), or those under a
  key that holds a server's TLS options (`transport_options:` for
  ThousandIsland, `thousand_island_options:` for Bandit, `socket_opts:`
  for Ranch, `options:` for Plug.Cowboy). The same mention nested under
  `plug:` or `handler_options:` is the plug's or the handler's own —
  a reverse proxy's options for the upstream it dials, a client — and a
  server whose options name a CA to check clients against (`cacerts`,
  `cacertfile`), a `verify_fun` or `fail_if_no_peer_cert` meant to
  authenticate its clients, and turns that off with `verify_none`.

  `tree/3` rebuilds the value from the writes that reach the register:
  literals, list cells, tuples, maps, and the calls that build an option
  list of their arguments (`Keyword.put/3`, `Keyword.merge/2`, `++`). What
  it cannot follow (a parameter, another call's result) is opaque and
  holds no key. `entries/1` lists what the tree holds: each key with the
  path of keys down to it, and each literal value with its path and the
  instruction it appears in.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @typedoc "A value as the function builds it."
  @type tree ::
          {:lit, term(), non_neg_integer()}
          | {:cons, tree(), tree()}
          | {:tuple, [tree()]}
          | {:map, tree(), [{tree(), tree()}]}
          | {:put, tree(), tree(), tree()}
          | {:merge, [tree()]}
          | {:join, [tree()]}
          | :opaque

  @typedoc "What a tree holds: a key at a path, or a literal at one."
  @type entry :: {:key, [term()]} | {:value, [term()], term(), non_neg_integer()}

  @depth 24

  # Calls that build an option list of their arguments: {positions of
  # lists merged} or {:put, list, key, value} positions.
  @merges %{
    {Keyword, :merge, 2} => {:merge, [0, 1]},
    {:lists, :append, 2} => {:merge, [0, 1]},
    {:erlang, :++, 2} => {:merge, [0, 1]},
    {Enum, :concat, 2} => {:merge, [0, 1]},
    {Map, :merge, 2} => {:merge, [0, 1]},
    {:maps, :merge, 2} => {:merge, [0, 1]},
    {Keyword, :put, 3} => {:put, 0, 1, 2},
    {Keyword, :put_new, 3} => {:put, 0, 1, 2},
    {Map, :put, 3} => {:put, 0, 1, 2},
    {Map, :put_new, 3} => {:put, 0, 1, 2},
    {:maps, :put, 3} => {:put, 2, 0, 1},
    {:lists, :keystore, 4} => {:put, 2, 0, 3}
  }

  @doc "The value `register` holds before instruction `idx`, as a tree."
  @spec tree([term()], non_neg_integer(), term()) :: tree()
  def tree(instrs, idx, register), do: reg_tree(instrs, idx, Instr.register(register), @depth)

  defp reg_tree(_instrs, _idx, _reg, 0), do: :opaque

  defp reg_tree(instrs, idx, reg, depth) do
    if register?(reg) do
      case writers(instrs, idx, reg, depth) do
        [] -> :opaque
        [one] -> one
        several -> {:join, several}
      end
    else
      :opaque
    end
  end

  # The trees of the writes that reach `reg`, copies followed.
  defp writers(instrs, idx, reg, depth) do
    instrs
    |> Reaching.sources(idx, reg)
    |> Enum.map(fn
      {:param, _} ->
        :opaque

      at ->
        instr = Reaching.at(instrs, at)

        case Instr.copy_source(instr, reg) do
          {kind, _} = source when kind in [:x, :y] -> reg_tree(instrs, at, source, depth - 1)
          _ -> instr_tree(instrs, at, instr, depth - 1)
        end
    end)
    |> Enum.uniq()
  end

  defp instr_tree(instrs, at, {:move, src, _dst}, depth), do: operand(instrs, at, src, depth)

  defp instr_tree(instrs, at, {:put_list, head, tail, _dst}, depth),
    do: {:cons, operand(instrs, at, head, depth), operand(instrs, at, tail, depth)}

  defp instr_tree(instrs, at, {:put_tuple2, _dst, {:list, elems}}, depth),
    do: {:tuple, Enum.map(elems, &operand(instrs, at, &1, depth))}

  defp instr_tree(instrs, at, {op, _fail, src, _dst, _live, {:list, kvs}}, depth)
       when op in [:put_map_assoc, :put_map_exact] do
    pairs =
      for [k, v] <- Enum.chunk_every(kvs, 2),
          do: {operand(instrs, at, k, depth), operand(instrs, at, v, depth)}

    {:map, operand(instrs, at, src, depth), pairs}
  end

  defp instr_tree(instrs, at, instr, depth) do
    with {:ok, m, f, a} <- Helpers.match_remote_call(instr),
         {:ok, how} <- Map.fetch(@merges, {m, f, a}) do
      arg = &reg_tree(instrs, at, {:x, &1}, depth)

      case how do
        {:merge, positions} -> {:merge, Enum.map(positions, arg)}
        {:put, list, key, value} -> {:put, arg.(list), arg.(key), arg.(value)}
      end
    else
      _ -> :opaque
    end
  end

  defp operand(instrs, at, operand, depth) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> reg_tree(instrs, at, reg, depth)
      _ -> literal(operand, at)
    end
  end

  defp literal({:literal, value}, at), do: {:lit, value, at}
  defp literal({:atom, value}, at), do: {:lit, value, at}
  defp literal({:integer, value}, at), do: {:lit, value, at}
  defp literal({:float, value}, at), do: {:lit, value, at}
  defp literal(nil, at), do: {:lit, [], at}
  defp literal(_operand, _at), do: :opaque

  defp register?({kind, n}) when kind in [:x, :y] and is_integer(n), do: true
  defp register?(_operand), do: false

  @doc """
  What `tree` holds, read as options: every key with the path of keys to
  it (the key last), and every literal value with its path and the
  instruction it is written in. A list's element that is not a pair, a
  tuple's elements and a map's are under `:elem`.
  """
  @spec entries(tree()) :: [entry()]
  def entries(tree), do: tree |> walk([]) |> Enum.uniq()

  defp walk({:lit, value, at}, path), do: literal_entries(value, path, at)

  defp walk({:cons, head, tail}, path), do: element(head, path) ++ walk(tail, path)

  defp walk({:tuple, elems}, path), do: Enum.flat_map(elems, &walk(&1, path ++ [:elem]))

  defp walk({:map, base, pairs}, path) do
    walk(base, path) ++ Enum.flat_map(pairs, fn {k, v} -> pair(k, v, path) end)
  end

  defp walk({:put, base, key, value}, path), do: walk(base, path) ++ pair(key, value, path)

  defp walk({tag, trees}, path) when tag in [:merge, :join],
    do: Enum.flat_map(trees, &walk(&1, path))

  defp walk(:opaque, _path), do: []

  # A list's element: a `{key, value}` pair is the value under the key.
  defp element({:tuple, [key, value]}, path), do: pair(key, value, path)
  defp element({:lit, value, at}, path), do: literal_element(value, path, at)
  defp element({:join, trees}, path), do: Enum.flat_map(trees, &element(&1, path))
  defp element(tree, path), do: walk(tree, path ++ [:elem])

  defp pair({:lit, key, _}, value, path) when is_atom(key),
    do: [{:key, path ++ [key]} | walk(value, path ++ [key])]

  defp pair(_key, value, path), do: walk(value, path ++ [:elem])

  defp literal_entries(value, path, at) when is_list(value) do
    value |> proper() |> Enum.flat_map(&literal_element(&1, path, at))
  end

  defp literal_entries(value, path, at) when is_map(value) do
    Enum.flat_map(value, fn
      {k, v} when is_atom(k) -> [{:key, path ++ [k]} | literal_entries(v, path ++ [k], at)]
      {_k, v} -> literal_entries(v, path ++ [:elem], at)
    end)
  end

  defp literal_entries(value, path, at) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.flat_map(&literal_entries(&1, path ++ [:elem], at))
  end

  defp literal_entries(value, path, at), do: [{:value, path, value, at}]

  defp literal_element({key, value}, path, at) when is_atom(key),
    do: [{:key, path ++ [key]} | literal_entries(value, path ++ [key], at)]

  defp literal_element(value, path, at), do: literal_entries(value, path ++ [:elem], at)

  # The elements of a list, its improper tail as one more.
  defp proper([head | tail]), do: [head | proper(tail)]
  defp proper([]), do: []
  defp proper(tail), do: [tail]
end
