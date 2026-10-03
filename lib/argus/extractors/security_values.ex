defmodule Argus.Extractors.SecurityValues do
  @moduledoc """
  Exact local values and narrowly scoped safety proofs at call arguments.

  Identity follows copies and map/tuple projections through reaching definitions.
  A field retains its parent, and a call result retains its site. Unknown joins
  never establish identity. Safety is a separate must-property: every reaching
  writer must establish it. A sanitizer of another value has no effect.

  Byte-size bounds require a comparison of this same value before the use, and
  removal of the accepting CFG edge must make the use unreachable. This includes
  rejecting branches and excludes checks after use or on only one incoming path.
  The extractor deliberately does not infer path containment from normalization,
  SQL safety from arbitrary replacement, or allocation bounds from byte limits.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues.Binary, as: BinaryValues
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @max_depth 48
  @properties ["html_text", "path_basename"]

  @impl true
  def relations do
    [
      :security_arg_value,
      :security_value_origin,
      :security_value_field,
      :security_arg_safe,
      :security_arg_limit
    ]
  end

  @impl true
  def extract(module_data) do
    sites = Enum.group_by(CallSites.for_module(module_data), & &1.func_id)

    module_data.functions
    |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func = InstrId.func_id(module_data.module, name, arity)
      calls = Map.get(sites, func, [])

      if calls == [] do
        facts
      else
        cfg = proof_cfg(Helpers.cfg(module_data, name, arity), instrs)
        bounds = bounds(instrs)
        binary_types = html_binary_types(cfg, instrs)

        Enum.reduce(calls, facts, fn site, acc ->
          emit_call(acc, site, cfg, bounds, binary_types)
        end)
      end
    end)
    |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
  end

  defp emit_call(facts, %{mfa: {_, _, arity}} = site, cfg, bounds, binary_types) do
    id = InstrId.mint(site.func_id, site.idx)

    for pos <- positions(arity), reduce: facts do
      facts ->
        value = identity_at(site.instrs, site.idx, {:x, pos})
        prefix = [id, site.func_id, to_string(pos)]

        facts =
          if value do
            facts
            |> emit_value(site.func_id, value)
            |> add_fact(:security_arg_value, prefix ++ [value_id(site.func_id, value)])
          else
            facts
          end

        facts =
          Enum.reduce(@properties, facts, fn property, acc ->
            if safe_at?(site.instrs, site.idx, {:x, pos}, property, binary_types),
              do: add_fact(acc, :security_arg_safe, prefix ++ [property]),
              else: acc
          end)

        Enum.reduce(bounds, facts, fn {checked, at, edge, limit}, acc ->
          if value != nil and checked == value and edge_covers?(cfg, at, edge, site.idx),
            do: add_fact(acc, :security_arg_limit, prefix ++ ["byte_size", to_string(limit)]),
            else: acc
        end)
    end
  end

  defp positions(0), do: []
  defp positions(arity), do: 0..(min(arity, 4) - 1)

  @doc """
  Refines a CFG for safety proofs by removing fallthrough after known
  unconditional error, throw and exit calls. Exception-handler edges already
  present in the graph remain. Unknown calls and erlang:raise/3 retain their
  edges because they may return.
  """
  @spec proof_cfg(CfgFunction.t() | nil, [term()]) :: CfgFunction.t() | nil
  def proof_cfg(nil, _instrs), do: nil

  def proof_cfg(cfg, instrs) do
    blocks =
      Map.new(cfg.blocks, fn {id, block} ->
        {first, last} = block.range

        raises? =
          Enum.any?(first..last, fn at ->
            case Helpers.match_remote_call(Reaching.at(instrs, at)) do
              {:ok, :erlang, :error, arity} when arity in [1, 2, 3] -> true
              {:ok, :erlang, fun, 1} when fun in [:throw, :exit] -> true
              _ -> false
            end
          end)

        successors =
          if raises?,
            do: Enum.filter(block.succs, &(elem(&1, 1) == :exception)),
            else: block.succs

        {id, %{block | succs: successors}}
      end)

    %{cfg | blocks: blocks}
  end

  @doc """
  One exact local identity at an instruction, or nil when reaching paths disagree.
  Returned terms are parameters, call sites, literals, local writes, or nested
  field projections; they contain no runtime resources and are function-relative.
  """
  @spec identity_at([term()], non_neg_integer(), term()) :: term() | nil
  def identity_at(instrs, idx, reg), do: identify(instrs, idx, reg, %{})

  @spec identify([term()], non_neg_integer(), term(), map()) :: term()
  defp identify(instrs, idx, operand, seen) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        key = {idx, reg}

        if map_size(seen) >= @max_depth or Map.has_key?(seen, key) do
          nil
        else
          next = Map.put(seen, key, true)

          instrs
          |> Reaching.sources(idx, reg)
          |> agree(fn
            {:param, pos} -> {:param, pos}
            at -> identify_write(instrs, at, reg, next)
          end)
        end

      other ->
        literal_identity(other)
    end
  end

  defp identify_write(instrs, at, reg, seen) do
    instr = Reaching.at(instrs, at)

    case Instr.copy_source(instr, reg) do
      nil -> identify_made(instrs, at, instr, reg, seen)
      source -> identify(instrs, at, source, seen)
    end
  end

  defp identify_made(instrs, at, {:get_tuple_element, src, n, _}, _, seen),
    do: field(identify(instrs, at, src, seen), :tuple, n)

  defp identify_made(instrs, at, {:get_map_elements, _, src, {:list, pairs}}, reg, seen) do
    key =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.find_value(fn [key, dst] ->
        if Instr.register(dst) == reg, do: literal_identity(Instr.register(key))
      end)

    case key do
      {:literal, key} -> field(identify(instrs, at, src, seen), :map, key)
      nil -> nil
    end
  end

  defp identify_made(instrs, at, {:bif, name, _, args, _}, _, seen),
    do: identify_bif(instrs, at, name, args, seen)

  defp identify_made(instrs, at, {:gc_bif, name, _, _, args, _}, _, seen),
    do: identify_bif(instrs, at, name, args, seen)

  defp identify_made(instrs, at, instr, reg, seen) do
    case Helpers.match_remote_call(instr) do
      {:ok, :maps, :get, 2} ->
        map_get_identity(instrs, at, {:x, 0}, {:x, 1}, seen)

      _ ->
        if Instr.call?(instr), do: {:call, at}, else: {:local, at, reg}
    end
  end

  defp identify_bif(instrs, at, :element, [{:integer, n}, src], seen) when n > 0,
    do: field(identify(instrs, at, src, seen), :tuple, n - 1)

  defp identify_bif(instrs, at, :map_get, [key, src], seen),
    do: map_get_identity(instrs, at, key, src, seen)

  defp identify_bif(_instrs, at, _name, _args, _seen), do: {:local, at, {:x, 0}}

  defp map_get_identity(instrs, at, key, src, seen) do
    case identify(instrs, at, key, seen) do
      {:literal, key} -> field(identify(instrs, at, src, seen), :map, key)
      _ -> nil
    end
  end

  defp field(nil, _kind, _key), do: nil
  defp field(parent, kind, key), do: {:field, parent, kind, key}

  defp literal_identity({kind, value}) when kind in [:literal, :atom, :integer, :float],
    do: {:literal, value}

  defp literal_identity(nil), do: {:literal, []}
  defp literal_identity(_), do: nil

  defp agree([], _fun), do: nil

  defp agree([source | sources], fun) do
    first = fun.(source)
    if first != nil and Enum.all?(sources, &(fun.(&1) == first)), do: first
  end

  defp value_id(func, identity), do: Terms.spell({func, identity})

  defp emit_value(facts, func, {:field, parent, kind, key} = value) do
    key = if kind == :tuple, do: to_string(key), else: Terms.spell(key)

    facts
    |> emit_value(func, parent)
    |> add_fact(:security_value_field, [
      value_id(func, value),
      value_id(func, parent),
      to_string(kind),
      key
    ])
  end

  defp emit_value(facts, func, value) do
    {kind, source} =
      case value do
        {:param, pos} -> {"param", to_string(pos)}
        {:call, at} -> {"call", InstrId.mint(func, at)}
        {:literal, literal} -> {"literal", Terms.spell(literal)}
        {:local, at, reg} -> {"local", InstrId.mint(func, at) <> ":" <> Terms.spell(reg)}
      end

    add_fact(facts, :security_value_origin, [value_id(func, value), func, kind, source])
  end

  @doc """
  Whether every reaching writer establishes the named property. html_text accepts
  literals and HTML escaping, including conversion of escaped iodata to a binary.
  path_basename describes basename's returned value only; it is not containment.
  """
  @spec safe_at?([term()], non_neg_integer(), term(), String.t()) :: boolean()
  def safe_at?(instrs, idx, reg, property), do: safe_at?(instrs, idx, reg, property, %{})

  @doc "Like safe_at?/4, with precomputed must-binary facts for guarded conversion paths."
  @spec safe_at?([term()], non_neg_integer(), term(), String.t(), map()) :: boolean()
  def safe_at?(instrs, idx, reg, property, binary_types) when property in @properties do
    Resolve.trace(instrs, idx, reg, false, fn
      {:param, _}, _follow -> false
      {at, instr}, follow -> safe_write(instrs, at, instr, property, follow, binary_types)
    end)
  end

  def safe_at?(_instrs, _idx, _reg, _property, _binary_types), do: false

  defp safe_write(_instrs, _at, instr, "path_basename", _follow, _binary_types) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, :basename, arity} when mod in [Path, :filename] and arity in [1, 2] -> true
      _ -> false
    end
  end

  defp safe_write(instrs, at, instr, property, follow, binary_types)
       when property in ["html_text", "html_plain"] do
    case Helpers.match_remote_call(instr) do
      {:ok, Plug.HTML, :html_escape, 1} ->
        true

      {:ok, Phoenix.HTML, :html_escape, 1} ->
        # Phoenix deliberately passes {:safe, contents} through unchanged.
        # An arbitrary value therefore does not become escaped by this call.
        MapSet.member?(Map.get(binary_types, at, MapSet.new()), {:x, 0}) or
          binary_at?(instrs, at, {:x, 0})

      {:ok, String, :replace, arity} when arity in [3, 4] ->
        with {:ok, replacement} when is_binary(replacement) <-
               Resolve.resolve_register(instrs, at, {:x, 2}) do
          # Replacing bytes in existing markup can change an inert tag into
          # a script (for example span -> script). Require input with no raw
          # markup before admitting a highlighting replacement.
          plain_html_at?(instrs, at, {:x, 0}, binary_types) and
            html_fragment?(replacement, property)
        else
          _ -> false
        end

      {:ok, mod, fun, 1}
      when {mod, fun} in [
             {Phoenix.HTML, :safe_to_string},
             {IO, :iodata_to_binary},
             {:erlang, :iolist_to_binary},
             {List, :to_string}
           ] ->
        follow.(at, {:x, 0})

      _ ->
        safe_html_structure(at, instr, follow, property)
    end
  end

  defp plain_html_at?(instrs, idx, reg, binary_types) do
    Resolve.trace(instrs, idx, reg, false, fn
      {:param, _}, _follow -> false
      {at, instr}, follow -> safe_write(instrs, at, instr, "html_plain", follow, binary_types)
    end)
  end

  defp safe_html_structure(at, {:move, operand, _}, follow, property),
    do: safe_html_operand(at, operand, follow, property)

  defp safe_html_structure(at, {:put_list, head, tail, _}, follow, property),
    do:
      safe_html_operand(at, head, follow, property) and
        safe_html_operand(at, tail, follow, property)

  defp safe_html_structure(at, {:bs_create_bin, _, _, _, _, _, {:list, parts}}, follow, property) do
    # Text escaping cannot protect interpolation into a script, URL, or attribute.
    # Restrict supported literal surroundings to text and complete inert inline
    # tags. Every dynamic segment must separately have HTML-text safety.
    parts
    |> Enum.chunk_every(6)
    |> Enum.all?(fn
      [{:atom, :string}, _, 8, _, {:string, text}, {:integer, size}] ->
        binary = IO.iodata_to_binary(text)
        size == byte_size(binary) and html_fragment?(binary, property)

      [{:atom, :binary}, _, 8, _, source, {:atom, :all}] ->
        safe_html_operand(at, source, follow, property)

      _ ->
        false
    end)
  end

  defp safe_html_structure(_at, _instr, _follow, _property), do: false

  defp safe_html_operand(at, operand, follow, property) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        follow.(at, reg)

      other ->
        case literal_identity(other) do
          {:literal, text} when is_binary(text) -> html_fragment?(text, property)
          {:literal, []} -> true
          {:literal, n} when is_integer(n) -> n not in [?<, ?>]
          {:literal, literal} when is_atom(literal) -> true
          _ -> false
        end
    end
  end

  defp binary_at?(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, false, fn
      {_at, {:move, {:literal, value}, _}}, _ -> is_binary(value)
      {_at, {:bs_create_bin, _, _, _, _, _, _}}, _ -> true
      {_at, instr}, _ -> binary_result?(instr)
      _, _ -> false
    end)
  end

  defp binary_result?(instr) do
    BinaryValues.binary_result?(instr)
  end

  @doc "Precomputes binary type proofs only for functions containing Phoenix escaping."
  @spec html_binary_types(CfgFunction.t() | nil, [term()]) :: map()
  def html_binary_types(cfg, instrs) do
    if Enum.any?(
         instrs,
         &(Helpers.match_remote_call(&1) == {:ok, Phoenix.HTML, :html_escape, 1})
       ), do: BinaryValues.types(cfg, instrs), else: %{}
  end

  defp html_fragment?(text, "html_plain"), do: not String.contains?(text, ["<", ">"])

  defp html_fragment?(text, "html_text") do
    without_tags = Regex.replace(~r/<\/?(?:b|strong|mark|em|i|span)>/, text, "")
    not String.contains?(without_tags, ["<", ">"])
  end

  defp bounds(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, op, _, [a, b]}, at} when op in [:is_ge, :is_lt] ->
        comparison_bounds(instrs, at, op, a, b)

      _ ->
        []
    end)
  end

  defp comparison_bounds(instrs, at, op, a, b) do
    case {size_of(instrs, at, a), integer_at(instrs, at, b), integer_at(instrs, at, a),
          size_of(instrs, at, b)} do
      {value, limit, _, _} when value != nil and is_integer(limit) and limit > 0 ->
        edge = if op == :is_lt, do: :branch_pass, else: :branch_fail
        [{value, at, edge, limit - 1}]

      {_, _, limit, value} when value != nil and is_integer(limit) and limit >= 0 ->
        edge = if op == :is_ge, do: :branch_pass, else: :branch_fail
        [{value, at, edge, limit}]

      _ ->
        []
    end
  end

  defp integer_at(instrs, at, operand) do
    case identity_at(instrs, at, operand) do
      {:literal, n} when is_integer(n) -> n
      _ -> nil
    end
  end

  defp size_of(instrs, at, reg) do
    Resolve.trace(instrs, at, reg, nil, fn
      {idx, {:bif, :byte_size, _, [src], _}}, _ ->
        identity_at(instrs, idx, src)

      {idx, {:gc_bif, :byte_size, _, _, [src], _}}, _ ->
        identity_at(instrs, idx, src)

      {idx, instr}, _ when is_integer(idx) ->
        case Helpers.match_remote_call(instr) do
          {:ok, :erlang, :byte_size, 1} -> identity_at(instrs, idx, {:x, 0})
          _ -> nil
        end

      _, _ ->
        nil
    end)
  end

  @doc "Whether every CFG path from entry to use passes through a particular branch edge."
  @spec edge_covers?(
          CfgFunction.t() | nil,
          non_neg_integer(),
          Argus.Cfg.Block.edge_kind(),
          non_neg_integer()
        ) ::
          boolean()
  def edge_covers?(nil, _at, _edge, _use), do: false

  def edge_covers?(cfg, at, edge, use) do
    with %{id: branch, range: {_, ^at}, succs: succs} <- CfgFunction.block_at(cfg, at),
         %{id: target} <- CfgFunction.block_at(cfg, use),
         true <- branch != target,
         {next, ^edge} <- Enum.find(succs, fn {_, kind} -> kind == edge end) do
      CfgFunction.dominates?(cfg, branch, target) and
        not reachable?(cfg, [cfg.entry], target, {branch, next, edge}, %{})
    else
      _ -> false
    end
  end

  @spec reachable?(CfgFunction.t(), [non_neg_integer()], non_neg_integer(), tuple(), map()) ::
          boolean()
  defp reachable?(_cfg, [], _target, _cut, _seen), do: false
  defp reachable?(_cfg, [target | _], target, _cut, _seen), do: true

  defp reachable?(cfg, [at | rest], target, cut, seen) do
    if Map.has_key?(seen, at) do
      reachable?(cfg, rest, target, cut, seen)
    else
      next = for {to, edge} <- Map.fetch!(cfg.blocks, at).succs, {at, to, edge} != cut, do: to
      reachable?(cfg, next ++ rest, target, cut, Map.put(seen, at, true))
    end
  end
end
