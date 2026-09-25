defmodule Argus.Extractors.ParamFlow.Propagators do
  @moduledoc """
  The calls whose result carries their argument's data.

  A call's result is derived from a parameter only when the callee is
  known to hand the argument's data through: a decoder, an accessor, a
  string or collection operation. Everything else — a database read, a
  process call, a size, a boolean — yields a result the extractor treats
  as fresh, and any real flow through such a callee is the interprocedural
  rule's business, never this table's. Missing an entry therefore costs a
  finding, not a false one.

  Callees are spelled as the bytecode spells them: `Kernel.to_string/1`
  is `String.Chars.to_string/1`, `conn.params` outside a pattern is
  `:elixir_erl_pass.no_parens_remote/2`, and `Map.get/2` in a pipeline is
  often `:maps.get/2` after inlining.
  """

  @typedoc "The argument positions whose data reaches the result."
  @type positions :: [non_neg_integer()]

  # {module, functions, arities, positions}: `:any` matches every function
  # of the module or every arity of the function. The positions are the
  # OTP and Elixir signatures' — `:maps.get(Key, Map)` carries its map,
  # position 1 — and `Argus.Extractors.ParamFlow.PropagatorsTest` checks
  # every entry against the documented argument names.
  @spec_table [
    {:erlang,
     ~w(binary_to_list list_to_binary iolist_to_binary tuple_to_list list_to_tuple binary_part
        split_binary atom_to_binary term_to_binary hd tl)a, :any, [0]},
    {:erlang, ~w(element map_get)a, :any, [1]},
    {:erlang, [:++], 2, [0, 1]},
    {:maps, [:get], 2, [1]},
    {:maps, [:get], 3, [1, 2]},
    {:maps, ~w(keys values to_list from_list)a, :any, [0]},
    {:maps, [:find], 2, [1]},
    {:maps, [:put], 3, [1, 2]},
    {:maps, [:merge], 2, [0, 1]},
    {:maps, [:update], 3, [1, 2]},
    {:maps, ~w(take remove with without filter map)a, :any, [1]},
    {:lists, ~w(reverse append flatten sort usort concat last droplast sublist)a, 1, [0]},
    {:lists, ~w(sublist)a, :any, [0]},
    {:lists, ~w(reverse append flatten)a, 2, [0, 1]},
    {:lists, ~w(sort usort nthtail nth)a, 2, [1]},
    {:lists, [:keyfind], 3, [2]},
    {:lists, [:zip], 2, [0, 1]},
    {:lists, [:join], 2, [0, 1]},
    {:lists, [:split], 2, [1]},
    {:binary, :any, :any, [0]},
    {:binary, [:replace], :any, [0, 2]},
    {:string, :any, :any, [0]},
    {:string, [:replace], :any, [0, 2]},
    {:unicode, :any, :any, [0]},
    {Access, ~w(get fetch fetch!)a, :any, [0]},
    {:elixir_erl_pass, [:no_parens_remote], 2, [0]},
    {String, :any, :any, [0]},
    {String, ~w(replace pad_leading pad_trailing)a, :any, [0, 2]},
    {Enum, ~w(at fetch fetch! map filter reject take drop reverse sort sort_by uniq uniq_by concat
        flat_map to_list slice split chunk_every with_index group_by frequencies min max
        find)a, :any, [0]},
    {Enum, ~w(into zip join map_join)a, :any, [0, 1]},
    {Enum, [:reduce], 2, [0]},
    {Enum, [:reduce], 3, [0, 1]},
    {List, ~w(first last flatten to_string to_charlist wrap delete to_tuple zip keyfind)a, :any,
     [0]},
    {List, ~w(insert_at replace_at)a, 3, [0, 2]},
    {List, [:update_at], 3, [0]},
    {Map,
     ~w(get fetch fetch! keys values to_list new take drop split pop from_struct filter reject
        update!)a, :any, [0]},
    {Map, [:get], 3, [0, 2]},
    {Map, ~w(put put_new)a, 3, [0, 2]},
    {Map, [:merge], :any, [0, 1]},
    {Map, [:update], 4, [0, 2]},
    {Keyword, ~w(get fetch fetch! keys values take drop delete pop)a, :any, [0]},
    {Keyword, [:get], 3, [0, 2]},
    {Keyword, [:put], 3, [0, 2]},
    {Keyword, [:merge], 2, [0, 1]},
    {Tuple, ~w(to_list delete_at)a, :any, [0]},
    {Tuple, [:insert_at], 3, [0, 2]},
    {Tuple, [:append], 2, [0, 1]},
    {String.Chars, [:to_string], 1, [0]},
    {List.Chars, [:to_charlist], 1, [0]},
    {Kernel, ~w(inspect get_in then)a, :any, [0]},
    {Kernel, ~w(struct struct!)a, 2, [0, 1]},
    {Kernel, [:put_in], 3, [0, 2]},
    {Jason, ~w(decode decode! encode encode!)a, :any, [0]},
    {JSON, ~w(decode decode!)a, :any, [0]},
    {:json, [:decode], :any, [0]},
    {Base, ~w(decode64 decode64! url_decode64 url_decode64! encode64 decode16 decode16!)a, :any,
     [0]},
    {URI, ~w(decode decode_www_form decode_query parse new)a, :any, [0]},
    {Plug.Conn.Query, [:decode], :any, [0]},
    {Plug.Conn, ~w(get_req_header fetch_query_params read_body)a, :any, [0]},
    # fetch_cookies/2 names the cookies to verify: `signed:` and
    # `encrypted:` values in the conn it returns are the server's own
    # (firezone's session cookies, decoded with binary_to_term), and the
    # conn is fresh rather than carry its other data along with them.
    {Plug.Conn, [:fetch_cookies], 1, [0]},
    {Plug.Conn.Utils, :any, :any, [0]}
  ]

  @doc """
  The table: `{module, functions, arities, positions}`, where `functions`
  and `arities` are lists or `:any`.
  """
  @spec entries() :: [{module(), [atom()] | :any, [arity()] | arity() | :any, positions()}]
  def entries, do: @spec_table

  # `element/2` and `hd/1` and friends compile to BIF instructions rather
  # than calls, with their operands in the signature's order.
  @bifs %{
    {"element", 2} => [1],
    {"map_get", 2} => [1],
    {"hd", 1} => [0],
    {"tl", 1} => [0],
    {"binary_part", 2} => [0],
    {"binary_part", 3} => [0],
    {"++", 2} => [0, 1]
  }

  # Indexed as the facts spell the callee: an inspected module and a
  # function name, both strings.
  @by_callee Enum.reduce(@spec_table, %{}, fn {mod, funs, arities, positions}, acc ->
               Enum.reduce(List.wrap(funs), acc, fn fun, inner ->
                 Map.update(
                   inner,
                   {inspect(mod), to_string(fun)},
                   [{arities, positions}],
                   &(&1 ++ [{arities, positions}])
                 )
               end)
             end)

  @doc """
  The argument positions of `mod.fun/arity` whose data reaches its result,
  or `nil` when the call is not a propagator. `mod` and `fun` are the
  strings the `remote_call` fact carries.
  """
  @spec positions(String.t(), String.t(), non_neg_integer()) :: positions() | nil
  def positions(mod, fun, arity) do
    entries = Map.get(@by_callee, {mod, fun}, []) ++ Map.get(@by_callee, {mod, "any"}, [])

    entries
    |> Enum.filter(fn {arities, _positions} -> arity_matches?(arities, arity) end)
    |> Enum.flat_map(fn {_arities, positions} -> positions end)
    |> Enum.filter(&(&1 < arity))
    |> case do
      [] -> nil
      positions -> Enum.uniq(positions)
    end
  end

  @doc "Whether the `:erlang` BIF `fun` hands some operand's data to its result."
  @deprecated "Use bif_positions/2, which says which operand"
  @spec bif?(String.t()) :: boolean()
  def bif?(fun), do: Enum.any?(Map.keys(@bifs), &match?({^fun, _}, &1))

  @doc """
  The operand positions of the `:erlang` BIF `fun`/`arity` whose data
  reaches its result — `map_get(Key, Map)` carries its map — or `nil` when
  the BIF is not a propagator.
  """
  @spec bif_positions(String.t(), non_neg_integer()) :: positions() | nil
  def bif_positions(fun, arity), do: Map.get(@bifs, {fun, arity})

  defp arity_matches?(:any, _arity), do: true
  defp arity_matches?(arities, arity) when is_list(arities), do: arity in arities
  defp arity_matches?(arity, arity), do: true
  defp arity_matches?(_arities, _arity), do: false
end
