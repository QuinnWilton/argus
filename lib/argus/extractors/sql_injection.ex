defmodule Argus.Extractors.SqlInjection do
  @moduledoc """
  SQL byte construction and escaping tied to its lexical context.

  A bounded symbolic walk keeps literal delimiters beside parameter-derived
  fragments. It follows actual local helper returns and supported mapping
  callbacks, so quoting a helper's returned value can be checked at its use.
  Unknown operations do not establish an escaping proof. Alternative reaching
  writers remain alternatives: one escaped branch cannot protect another.
  A dynamically selected dollar delimiter needs a same-body exclusion proof and
  a valid, inexhaustible tag sequence. That protects the enclosing delimiter;
  identifier construction inside the body is still checked separately.

  SQL API statement arguments, SQL-prefixed query callback tuples, and deferred
  Postgrex.Stream options are execution boundaries. Bound values are separate.
  The latter boundary uses body-derived validation summaries, never validator
  names, to require rejection of null bytes and comment terminators for the
  exact options value on every returning path before persistence.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.SqlInjection.Comments
  alias Argus.Extractors.SqlInjection.DollarQuote
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @typep fragment ::
           binary()
           | :unknown
           | {:input, non_neg_integer(), %{String.t() => true}}
           | {:dollar_safe, [fragment()]}
  @typep fragments :: [[fragment()]]
  @typep context :: %{
           mfa: mfa(),
           instrs: [term()],
           functions: %{mfa() => [term()]},
           bindings: %{non_neg_integer() => fragments()},
           seen: %{term() => true}
         }

  @depth 80
  @variants 24
  @query_modules [Postgrex, Mariaex, MyXQL, Exqlite.Sqlite3, Ecto.Adapters.SQL]
  @query_functions [:query, :query!, :prepare, :prepare!, :prepare_execute, :prepare_execute!]
  @conversions [
    {String.Chars, :to_string, 1},
    {IO, :iodata_to_binary, 1},
    {:erlang, :iolist_to_binary, 1},
    {List, :to_string, 1},
    {:maps, :keys, 1},
    {:maps, :values, 1},
    {Map, :keys, 1},
    {Map, :values, 1}
  ]

  @impl true
  def relations, do: [:sql_input, :sql_input_safe, :sql_call_input, :sql_call_input_safe]

  @impl true
  def extract(data) do
    functions =
      Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
        {{data.module, name, arity}, instrs}
      end)

    validators = Comments.validators(data)

    functions
    |> Enum.sort()
    |> Enum.reduce(%{}, fn {mfa, instrs}, facts ->
      ctx = %{mfa: mfa, instrs: instrs, functions: functions, bindings: %{}, seen: %{}}

      instrs
      |> Enum.with_index()
      |> Enum.reduce(facts, fn {instr, at}, acc ->
        emit_instruction(acc, ctx, at, instr, data, validators)
      end)
    end)
    |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
  end

  defp emit_instruction(facts, ctx, at, instr, data, validators) do
    case boundary(instr) do
      {:statement, operand, boundary} ->
        parts = value(ctx, at, operand)
        parts = if boundary == :callback, do: Enum.filter(parts, &sql_prefix?/1), else: parts
        emit_parts(facts, ctx, at, parts, dialect(boundary, data))

      {:options, options} ->
        params = value(ctx, at, options) |> parameters()
        safe? = Comments.safe_options?(data, ctx.mfa, at, options, validators)
        emit_options(facts, ctx, at, params, safe?)

      nil ->
        emit_candidate_call(facts, ctx, at, instr)
    end
  end

  # The callee's generated adapter delegation is established across modules in
  # Datalog. A query-shaped name alone is not evidence of an SQL execution API.
  # Keep the caller's construction context so moving the boundary out of a
  # generated Repo wrapper does not discard injection at its application caller.
  defp emit_candidate_call(facts, ctx, at, instr) do
    call =
      case Helpers.match_remote_call(instr) do
        :none -> Helpers.match_local_call(instr)
        remote -> remote
      end

    case call do
      {:ok, mod, fun, arity} when fun in [:query, :query!] and arity in 1..3 ->
        parts = value(ctx, at, {:x, 0})
        callee = func_id({mod, fun, arity})

        %{}
        |> emit_parts(ctx, at, parts, :unknown)
        |> Enum.reduce(facts, fn {relation, rows}, acc ->
          Enum.reduce(rows, acc, fn [id, func, context, param], result ->
            row = [id, func, callee, context, param]

            case relation do
              :sql_input -> add_fact(result, :sql_call_input, row)
              :sql_input_safe -> add_fact(result, :sql_call_input_safe, row)
            end
          end)
        end)

      _ ->
        facts
    end
  end

  defp boundary({:put_tuple2, _, {:list, [{:atom, :query}, statement | _]}}),
    do: {:statement, statement, :callback}

  defp boundary({op, _, _, _, _, {:list, pairs}})
       when op in [:put_map_assoc, :put_map_exact] do
    fields = Map.new(Enum.chunk_every(pairs, 2), fn [key, value] -> {key, value} end)

    case fields do
      %{{:atom, :__struct__} => {:atom, Postgrex.Stream}, {:atom, :options} => options} ->
        {:options, options}

      _ ->
        nil
    end
  end

  defp boundary(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, arity}
      when mod in @query_modules and fun in @query_functions and arity >= 2 ->
        # prepare(conn, name, statement, ...) uses the third argument.
        named? = fun in [:prepare, :prepare!, :prepare_execute, :prepare_execute!]
        pos = if named? and mod != Exqlite.Sqlite3, do: 2, else: 1
        if arity > pos, do: {:statement, {:x, pos}, mod}

      _ ->
        nil
    end
  end

  defp dialect(:callback, data) do
    behaviours = Keyword.get_values(Map.get(data, :attributes, []), :behaviour) |> List.flatten()
    if Postgrex.SimpleConnection in behaviours, do: :postgres, else: :unknown
  end

  defp dialect(Postgrex, _data), do: :postgres
  defp dialect(Exqlite.Sqlite3, _data), do: :sqlite
  defp dialect(mod, _data) when mod in [Mariaex, MyXQL], do: :mysql
  defp dialect(_mod, _data), do: :unknown

  defp sql_prefix?(tokens) do
    prefix = tokens |> Enum.take_while(&is_binary/1) |> Enum.join()

    Regex.match?(
      ~r/^\s*(?:SELECT|INSERT|UPDATE|DELETE|LISTEN|UNLISTEN|NOTIFY|DO|WITH|ALTER|CREATE|DROP)\b/i,
      prefix
    )
  end

  defp emit_parts(facts, ctx, at, variants, dialect) do
    entries = Enum.flat_map(variants, &scan(&1, dialect))
    known? = not unknown?(variants)
    grouped = Enum.group_by(entries, fn {context, param, _safe} -> {context, param} end)
    func = func_id(ctx.mfa)
    id = InstrId.mint(func, at)

    Enum.reduce(grouped, facts, fn {{context, param}, occurrences}, acc ->
      row = [id, func, context, to_string(param)]
      acc = add_fact(acc, :sql_input, row)

      if known? and Enum.all?(occurrences, &elem(&1, 2)),
        do: add_fact(acc, :sql_input_safe, row),
        else: acc
    end)
  end

  defp emit_options(facts, ctx, at, params, safe?) do
    func = func_id(ctx.mfa)

    Enum.reduce(params, facts, fn param, acc ->
      row = [InstrId.mint(func, at), func, "comment", to_string(param)]
      acc = add_fact(acc, :sql_input, row)
      if safe?, do: add_fact(acc, :sql_input_safe, row), else: acc
    end)
  end

  # Each alternative is an ordered list of literal bytes and input fragments.
  # Reaching-definition alternatives must stay separate until safety is joined.
  @spec value(context(), non_neg_integer(), term()) :: fragments()
  defp value(ctx, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> register_value(ctx, at, reg)
      {:literal, literal} -> literal(literal)
      {:string, bytes} -> literal(bytes)
      {:integer, integer} when integer in 0..255 -> [[<<integer>>]]
      nil -> [[]]
      _ -> [[]]
    end
  end

  @spec register_value(context(), non_neg_integer(), term()) :: fragments()
  defp register_value(ctx, at, reg) do
    key = {ctx.mfa, at, reg}

    if map_size(ctx.seen) >= @depth or Map.has_key?(ctx.seen, key) do
      [[:unknown]]
    else
      next = %{ctx | seen: Map.put(ctx.seen, key, true)}

      ctx.instrs
      |> Reaching.sources(at, reg)
      |> Enum.flat_map(fn
        {:param, pos} -> Map.get(ctx.bindings, pos, [[{:input, pos, %{}}]])
        writer -> written(next, writer, reg)
      end)
      |> cap()
      |> nonempty()
    end
  end

  defp literal(binary) when is_binary(binary), do: [[binary]]

  defp literal(list) when is_list(list) do
    [[IO.iodata_to_binary(list)]]
  rescue
    ArgumentError -> [[]]
  end

  defp literal(_), do: [[]]

  defp written(ctx, at, reg) do
    instr = Reaching.at(ctx.instrs, at)

    case Instr.copy_source(instr, reg) do
      nil -> made(ctx, at, reg, instr)
      operand -> value(ctx, at, operand)
    end
  end

  defp made(ctx, at, _reg, {:bs_create_bin, _, _, _, _, _, {:list, segments}}) do
    segments
    |> Enum.chunk_every(6)
    |> Enum.map(fn
      [{:atom, :string}, _, _, _, {:string, bytes}, {:integer, size}] ->
        binary = if is_list(bytes), do: List.to_string(bytes), else: bytes
        [[binary_part(binary, 0, min(size, byte_size(binary)))]]

      [_, _, _, _, operand, _] ->
        value(ctx, at, operand)

      _ ->
        [[:unknown]]
    end)
    |> concatenate()
  end

  defp made(ctx, at, _reg, {:put_list, head, tail, _}),
    do: concatenate([value(ctx, at, head), value(ctx, at, tail)])

  defp made(ctx, at, _reg, {:get_tuple_element, source, _, _}),
    do: data(value(ctx, at, source))

  defp made(ctx, at, _reg, {:get_map_elements, _, source, _}),
    do: data(value(ctx, at, source))

  defp made(ctx, at, _reg, {op, source, _, _}) when op == :get_list,
    do: data(value(ctx, at, source))

  defp made(ctx, at, _reg, {op, source, _}) when op in [:get_hd, :get_tl],
    do: data(value(ctx, at, source))

  defp made(ctx, at, _reg, {op, _, source, _, _, _})
       when op in [:put_map_assoc, :put_map_exact],
       do: data(value(ctx, at, source))

  defp made(ctx, at, _reg, instr) do
    case call_target(instr) do
      nil -> structural(ctx, at, instr)
      mfa -> call(ctx, at, mfa)
    end
  end

  defp structural(ctx, at, instr) do
    # Only structural reads carry input; BIF operations that compute lengths,
    # hashes or booleans do not return the source's bytes.
    case instr do
      {:bif, name, _, args, _} when name in [:map_get, :element, :hd, :tl] ->
        args |> Enum.map(&value(ctx, at, &1)) |> concatenate() |> data()

      {:gc_bif, name, _, _, args, _} when name in [:map_get, :element, :hd, :tl] ->
        args |> Enum.map(&value(ctx, at, &1)) |> concatenate() |> data()

      {:put_tuple2, _, {:list, parts}} ->
        parts |> Enum.map(&value(ctx, at, &1)) |> concatenate() |> data()

      _ ->
        [[:unknown]]
    end
  end

  defp call(ctx, at, mfa) do
    cond do
      Map.has_key?(ctx.functions, mfa) ->
        local_result(ctx, at, mfa)

      mfa in @conversions ->
        value(ctx, at, {:x, 0})

      mfa in [{String, :replace, 3}, {String, :replace, 4}] ->
        replace(ctx, at, mfa)

      mfa in [{Enum, :map_join, 2}, {Enum, :map_join, 3}] ->
        mapped(ctx, at, mfa)

      mfa in [{:erlang, :++, 2}, {:lists, :append, 2}] ->
        concatenate([value(ctx, at, {:x, 0}), value(ctx, at, {:x, 1})])

      mfa in [{Keyword, :put_new, 3}, {Keyword, :put, 3}] ->
        case Resolve.resolve_register(ctx.instrs, at, {:x, 1}) do
          {:ok, key} when key != :comment -> value(ctx, at, {:x, 0})
          _ -> concatenate([value(ctx, at, {:x, 0}), value(ctx, at, {:x, 2})]) |> data()
        end

      mfa == {Keyword, :delete, 2} ->
        if Resolve.resolve_register(ctx.instrs, at, {:x, 1}) == {:ok, :comment},
          do: [[]],
          else: value(ctx, at, {:x, 0})

      mfa in [
        {Keyword, :get, 2},
        {Keyword, :get, 3},
        {Access, :get, 2},
        {Access, :get, 3},
        {Map, :get, 2},
        {Map, :get, 3},
        {:elixir_erl_pass, :no_parens_remote, 2}
      ] ->
        data(value(ctx, at, {:x, 0}))

      mfa == {:maps, :get, 2} ->
        data(value(ctx, at, {:x, 1}))

      true ->
        [[:unknown]]
    end
  end

  defp local_result(ctx, at, {_, _, arity} = mfa) do
    case DollarQuote.parameter(mfa, ctx.functions) do
      nil ->
        bindings = Map.new(positions(arity), &{&1, value(ctx, at, {:x, &1})})
        returns(%{ctx | mfa: mfa, instrs: Map.fetch!(ctx.functions, mfa), bindings: bindings})

      param ->
        Enum.map(value(ctx, at, {:x, param}), &[{:dollar_safe, &1}])
    end
  end

  @spec returns(context()) :: fragments()
  defp returns(ctx) do
    key = {:returns, ctx.mfa}

    if Map.has_key?(ctx.seen, key) do
      ctx.bindings |> Map.values() |> concatenate() |> data()
    else
      return_values(%{ctx | seen: Map.put(ctx.seen, key, true)})
    end
  end

  defp return_values(ctx) do
    ctx.instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {:return, at} -> value(ctx, at, {:x, 0})
      {instr, at} -> if Instr.tail_call?(instr), do: tail_result(ctx, at, instr), else: []
    end)
    |> cap()
  end

  defp tail_result(ctx, at, instr) do
    case call_target(instr) do
      {:erlang, name, _} when name in [:error, :exit, :throw] -> []
      nil -> [[:unknown]]
      mfa -> call(ctx, at, mfa)
    end
  end

  defp mapped(ctx, at, {_, _, arity}) do
    item = mapped_item(ctx, at, arity)
    separator = if arity == 3, do: value(ctx, at, {:x, 1}), else: [[""]]

    # Separators are emitted between mapper results and have their own lexical
    # context. A known empty or singleton list never emits its separator.
    case Resolve.resolve_register(ctx.instrs, at, {:x, 0}) do
      {:ok, []} -> [[]]
      {:ok, [_]} -> item
      {:ok, [_, _ | _]} -> concatenate([item, separator, item])
      _ -> cap([[]] ++ item ++ concatenate([item, separator, item]))
    end
  end

  defp mapped_item(ctx, at, arity) do
    with mfa when mfa != nil <- Resolve.fun_target(ctx.instrs, at, {:x, arity - 1}),
         {:ok, instrs} <- Map.fetch(ctx.functions, mfa) do
      bindings =
        ctx
        |> captures(at, {:x, arity - 1})
        |> Map.put(0, data(value(ctx, at, {:x, 0})))

      returns(%{ctx | mfa: mfa, instrs: instrs, bindings: bindings})
    else
      _ -> [[:unknown]]
    end
  end

  defp captures(ctx, at, operand) do
    Resolve.trace(ctx.instrs, at, operand, %{}, fn
      {made, {:make_fun3, {_, _, arity}, _, _, _, {:list, environment}}}, _ ->
        first = arity - length(environment)

        environment
        |> Enum.with_index(first)
        |> Map.new(fn {operand, pos} -> {pos, value(ctx, made, operand)} end)

      _, _ ->
        %{}
    end)
  end

  defp replace(ctx, at, {_, _, arity}) do
    pattern = Resolve.resolve_register(ctx.instrs, at, {:x, 1})
    replacement = Resolve.resolve_register(ctx.instrs, at, {:x, 2})
    global? = arity == 3 or Resolve.resolve_register(ctx.instrs, at, {:x, 3}) == {:ok, []}

    context =
      case {pattern, replacement, global?} do
        {{:ok, "\""}, {:ok, "\"\""}, true} -> "identifier"
        _ -> nil
      end

    source = value(ctx, at, {:x, 0})

    if context do
      Enum.map(source, fn tokens ->
        Enum.map(tokens, fn
          {:input, pos, safe} -> {:input, pos, Map.put(safe, context, true)}
          literal when is_binary(literal) -> String.replace(literal, "\"", "\"\"")
          :unknown -> :unknown
          {:dollar_safe, _} -> :unknown
        end)
      end)
    else
      # Replacement can introduce control bytes even after an earlier escape.
      # Its result remains dependent on the source but retains no escaping proof.
      data(source)
    end
  end

  defp call_target(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, arity} ->
        {mod, fun, arity}

      :none ->
        case Helpers.match_local_call(instr) do
          {:ok, mod, fun, arity} -> {mod, fun, arity}
          :none -> nil
        end
    end
  end

  defp positions(0), do: []
  defp positions(arity), do: 0..(arity - 1)

  defp concatenate(parts) do
    Enum.reduce(parts, [[]], fn alternatives, acc ->
      cap(for left <- acc, right <- alternatives, do: left ++ right)
    end)
  end

  defp cap(parts) do
    parts = Enum.uniq(parts)

    if length(parts) <= @variants do
      parts
    else
      data(parts)
    end
  end

  defp data(parts) do
    inputs = for pos <- parameters(parts), do: {:input, pos, %{}}
    unknown = if unknown?(parts), do: [:unknown], else: []
    [inputs ++ unknown]
  end

  defp nonempty([]), do: [[:unknown]]
  defp nonempty(parts), do: parts

  defp parameters(parts) do
    parts |> Enum.flat_map(&Enum.flat_map(&1, fn token -> token_params(token) end)) |> Enum.uniq()
  end

  defp token_params({:input, pos, _}), do: [pos]
  defp token_params({:dollar_safe, body}), do: parameters([body])
  defp token_params(_), do: []

  defp unknown?(parts) do
    Enum.any?(parts, fn tokens ->
      Enum.any?(tokens, fn
        :unknown -> true
        {:dollar_safe, body} -> unknown?([body])
        _ -> false
      end)
    end)
  end

  defp func_id({mod, name, arity}), do: InstrId.func_id(mod, name, arity)

  # Parse only delimiters relevant to injection, preserving them across literal
  # fragments. A dollar quote is the outer lexical context even when its contents
  # are later parsed as a procedural body containing quoted identifiers.
  defp scan(tokens, dialect) do
    tokens = merge_literals(tokens)
    # Backslash interpretation in SQL string literals depends on dialect and
    # session settings. Do not use an identifier proof when surrounding literal
    # text leaves that interpretation ambiguous.
    stable_quoting? = not Enum.any?(tokens, &(is_binary(&1) and String.contains?(&1, "\\")))

    {_, rows} =
      Enum.reduce(tokens, {:statement, []}, fn
        literal, {state, rows} when is_binary(literal) ->
          {lex(literal, state), rows}

        {:input, param, safe}, {state, rows} ->
          context = context(state, dialect)

          escaped? =
            stable_quoting? and dialect in [:postgres, :sqlite] and Map.has_key?(safe, context)

          {state, [{context, param, escaped?} | rows]}

        :unknown, acc ->
          acc

        {:dollar_safe, body}, {:statement, rows} when dialect == :postgres ->
          protected = for param <- parameters([body]), do: {"dollar_quote", param, true}
          {:statement, protected ++ scan(body, dialect) ++ rows}

        {:dollar_safe, body}, {state, rows} ->
          exposed = for param <- parameters([body]), do: {context(state, dialect), param, false}
          {state, exposed ++ rows}
      end)

    rows
  end

  defp context(:identifier, :mysql), do: "string"
  defp context(:identifier, :unknown), do: "statement"
  defp context({:comment, _depth}, _dialect), do: "comment"
  defp context(:line_comment, _dialect), do: "comment"
  defp context(:escape_string, _dialect), do: "string"
  defp context(state, _dialect) when is_tuple(state), do: "dollar_quote"
  defp context(state, _dialect), do: to_string(state)

  defp merge_literals(tokens) do
    tokens
    |> Enum.reduce([], fn
      next, [previous | rest] when is_binary(next) and is_binary(previous) ->
        [previous <> next | rest]

      next, acc ->
        [next | acc]
    end)
    |> Enum.reverse()
  end

  defp lex(<<>>, state), do: state
  defp lex("/*" <> rest, :statement), do: lex(rest, {:comment, 1})
  defp lex("/*" <> rest, {:comment, depth}), do: lex(rest, {:comment, depth + 1})
  defp lex("*/" <> rest, {:comment, 1}), do: lex(rest, :statement)
  defp lex("*/" <> rest, {:comment, depth}), do: lex(rest, {:comment, depth - 1})
  defp lex("--" <> rest, :statement), do: lex(rest, :line_comment)
  defp lex("\n" <> rest, :line_comment), do: lex(rest, :statement)
  defp lex("\r" <> rest, :line_comment), do: lex(rest, :statement)

  defp lex(<<prefix, "'", rest::binary>>, :statement) when prefix in [?E, ?e],
    do: lex(rest, :escape_string)

  defp lex(<<"\\", _, rest::binary>>, :escape_string), do: lex(rest, :escape_string)
  defp lex("''" <> rest, :escape_string), do: lex(rest, :escape_string)
  defp lex("'" <> rest, :escape_string), do: lex(rest, :statement)
  defp lex("\"\"" <> rest, :identifier), do: lex(rest, :identifier)
  defp lex("\"" <> rest, :identifier), do: lex(rest, :statement)
  defp lex("\"" <> rest, :statement), do: lex(rest, :identifier)
  defp lex("''" <> rest, :string), do: lex(rest, :string)
  defp lex("'" <> rest, :string), do: lex(rest, :statement)
  defp lex("'" <> rest, :statement), do: lex(rest, :string)

  defp lex("$" <> _ = bytes, :statement) do
    case Regex.run(~r/^\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/, bytes) do
      [delimiter] ->
        size = byte_size(delimiter)
        lex(binary_part(bytes, size, byte_size(bytes) - size), {:dollar, delimiter})

      nil ->
        <<_, rest::binary>> = bytes
        lex(rest, :statement)
    end
  end

  defp lex(bytes, {:dollar, delimiter} = state) do
    if String.starts_with?(bytes, delimiter) do
      size = byte_size(delimiter)
      lex(binary_part(bytes, size, byte_size(bytes) - size), :statement)
    else
      <<_, rest::binary>> = bytes
      lex(rest, state)
    end
  end

  defp lex(<<_, rest::binary>>, state), do: lex(rest, state)
end
