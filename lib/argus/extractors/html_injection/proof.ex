defmodule Argus.Extractors.HtmlInjection.Proof do
  @moduledoc false

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  @type index :: %{
          functions: %{String.t() => [Instr.instr()]},
          types: %{String.t() => %{non_neg_integer() => MapSet.t(Instr.reg())}},
          callers: %{String.t() => [CallSites.site()]},
          open: MapSet.t(String.t())
        }

  @depth 96
  @variants 24
  @backslash 1
  @single 2
  @double 4
  @newline 8
  @carriage 16
  @closing_tag 32
  @single_safe @backslash + @single + @newline + @carriage + @closing_tag
  @double_safe @backslash + @double + @newline + @carriage + @closing_tag

  @spec index(Argus.Extractor.module_data()) :: index()
  def index(data) do
    functions =
      Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
        {InstrId.func_id(data.module, name, arity), instrs}
      end)

    types =
      Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
        {InstrId.func_id(data.module, name, arity), binary_types(data, name, arity, instrs)}
      end)

    callers = Enum.group_by(CallSites.for_module(data), &func_id(&1.mfa))

    # An escaped closure has callers the direct-call index cannot enumerate.
    closures =
      for {:function, _, _, _, instrs} <- data.functions,
          {:make_fun3, target, _, _, _, _} <- instrs,
          into: MapSet.new(),
          do: func_id(target)

    exports =
      MapSet.new(data.exports, fn export ->
        InstrId.func_id(data.module, elem(export, 0), elem(export, 1))
      end)

    %{functions: functions, types: types, callers: callers, open: MapSet.union(exports, closures)}
  end

  defp binary_types(data, name, arity, instrs) do
    if Enum.any?(instrs, &(Helpers.match_remote_call(&1) == {:ok, Phoenix.HTML, :html_escape, 1})) do
      SecurityValues.html_binary_types(Helpers.cfg(data, name, arity), instrs)
    else
      %{}
    end
  end

  @spec safe_at?(index(), String.t(), non_neg_integer(), term()) :: boolean()
  def safe_at?(index, func, at, operand) do
    ctx = %{
      index: index,
      func: func,
      instrs: Map.fetch!(index.functions, func),
      bindings: %{},
      seen: %{}
    }

    ctx |> value(at, operand) |> Enum.all?(&safe_document?/1)
  end

  # Each path is a sequence of literal bytes and fragments carrying the context
  # for which they were escaped. Path alternatives cannot establish each other's
  # safety, and budget exhaustion preserves an unknown fragment.
  defp value(ctx, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> register(ctx, at, reg)
      {:literal, literal} -> literal(literal)
      {:string, bytes} -> literal(bytes)
      {:integer, byte} when byte in 0..255 -> [[<<byte>>]]
      nil -> [[""]]
      _ -> unknown()
    end
  end

  defp register(ctx, at, reg) do
    key = {ctx.func, at, reg}

    if map_size(ctx.seen) >= @depth or Map.has_key?(ctx.seen, key) do
      unknown()
    else
      ctx = %{ctx | seen: Map.put(ctx.seen, key, true)}

      ctx.instrs
      |> Reaching.sources(at, reg)
      |> Enum.flat_map(fn
        {:param, pos} -> argument(ctx, pos)
        writer -> written(ctx, writer, reg)
      end)
      |> cap()
    end
  end

  defp literal(binary) when is_binary(binary), do: [[binary]]

  defp literal(list) when is_list(list) do
    [[IO.iodata_to_binary(list)]]
  rescue
    ArgumentError -> unknown()
  end

  defp literal(_), do: unknown()

  defp argument(ctx, pos) do
    case Map.fetch(ctx.bindings, pos) do
      {:ok, values} ->
        values

      :error ->
        callers = Map.get(ctx.index.callers, ctx.func, [])

        if MapSet.member?(ctx.index.open, ctx.func) or callers == [] do
          unknown()
        else
          callers
          |> Enum.flat_map(fn site ->
            caller = %{ctx | func: site.func_id, instrs: site.instrs, bindings: %{}}
            value(caller, site.idx, {:x, pos})
          end)
          |> cap()
        end
    end
  end

  defp written(ctx, at, reg) do
    instr = Reaching.at(ctx.instrs, at)

    case Instr.copy_source(instr, reg) do
      nil -> made(ctx, at, instr)
      source -> value(ctx, at, source)
    end
  end

  defp made(ctx, at, {:bs_create_bin, _, _, _, _, _, {:list, parts}}) do
    parts
    |> Enum.chunk_every(6)
    |> Enum.map(fn
      [{:atom, :string}, _, 8, _, {:string, bytes}, {:integer, size}] ->
        binary = IO.iodata_to_binary(bytes)
        if size == byte_size(binary), do: [[binary]], else: unknown()

      [{:atom, kind}, _, 8, _, operand, {:atom, :all}]
      when kind in [:binary, :append, :private_append] ->
        value(ctx, at, operand)

      _ ->
        unknown()
    end)
    |> concatenate()
  end

  defp made(ctx, at, {:put_list, head, tail, _}),
    do: concatenate([value(ctx, at, head), value(ctx, at, tail)])

  defp made(ctx, at, instr) do
    case called(instr) do
      nil -> unknown()
      mfa -> call(ctx, at, mfa)
    end
  end

  defp call(ctx, at, {mod, fun, arity} = mfa) do
    target = func_id(mfa)

    cond do
      Map.has_key?(ctx.index.functions, target) ->
        bindings = Map.new(0..(arity - 1)//1, &{&1, value(ctx, at, {:x, &1})})
        returns(%{ctx | func: target, instrs: ctx.index.functions[target], bindings: bindings})

      mfa == {Plug.HTML, :html_escape, 1} ->
        [[:html_text]]

      mfa == {Phoenix.HTML, :html_escape, 1} ->
        if known_binary_argument?(ctx, at),
          do: [[:html_text]],
          else: unknown()

      mfa == {String.Chars, :to_string, 1} ->
        # A protocol implementation may return an arbitrary term despite its
        # specification. Only the builtin binary implementation is identity.
        if known_binary_argument?(ctx, at), do: value(ctx, at, {:x, 0}), else: unknown()

      mfa in [{String, :replace, 3}, {String, :replace, 4}] ->
        replaced(ctx, at, arity)

      arity == 1 and
          {mod, fun} in [
            {IO, :iodata_to_binary},
            {:erlang, :iolist_to_binary},
            {Phoenix.HTML, :safe_to_string},
            {List, :to_string}
          ] ->
        value(ctx, at, {:x, 0})

      mfa in [{Integer, :to_string, 1}, {Integer, :to_string, 2}] ->
        [[:html_text]]

      true ->
        unknown()
    end
  end

  defp known_binary_argument?(ctx, at) do
    types = ctx.index.types[ctx.func]

    MapSet.member?(Map.get(types, at, MapSet.new()), {:x, 0}) or
      match?(
        {:ok, value} when is_binary(value),
        Resolve.resolve_register(ctx.instrs, at, {:x, 0})
      )
  end

  defp returns(ctx) do
    key = {:returns, ctx.func}

    if Map.has_key?(ctx.seen, key) or map_size(ctx.seen) >= @depth do
      unknown()
    else
      ctx = %{ctx | seen: Map.put(ctx.seen, key, true)}

      ctx.instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {:return, at} -> value(ctx, at, {:x, 0})
        {instr, at} -> if Instr.tail_call?(instr), do: made(ctx, at, instr), else: []
      end)
      |> cap()
    end
  end

  defp replaced(ctx, at, arity) do
    pattern = Resolve.resolve_register(ctx.instrs, at, {:x, 1})
    replacement = Resolve.resolve_register(ctx.instrs, at, {:x, 2})
    global? = arity == 3 or Resolve.resolve_register(ctx.instrs, at, {:x, 3}) == {:ok, []}

    with {{:ok, from}, {:ok, to}, true} when is_binary(from) and is_binary(to) <-
           {pattern, replacement, global?} do
      ctx
      |> value(at, {:x, 0})
      |> Enum.map(fn parts ->
        Enum.map(parts, fn
          text when is_binary(text) -> String.replace(text, from, to)
          {:javascript, bits} -> javascript_escape(bits, from, to)
          :unknown -> javascript_escape(0, from, to)
          _ -> :unknown
        end)
      end)
    else
      _ -> unknown()
    end
  end

  # Backslashes must be escaped first: doubling one introduced by quote escaping
  # would reopen the string. Unrecognized replacements invalidate the proof.
  defp javascript_escape(_bits, "\\", "\\\\"), do: {:javascript, @backslash}

  defp javascript_escape(bits, from, to) do
    flag =
      case {from, to} do
        {"'", "\\'"} -> @single
        {"\"", "\\\""} -> @double
        {"\n", "\\n"} -> @newline
        {"\r", "\\r"} -> @carriage
        {"</", "<\\/"} -> @closing_tag
        _ -> 0
      end

    if flag != 0 and Bitwise.band(bits, @backslash) != 0,
      do: {:javascript, Bitwise.bor(bits, flag)},
      else: :unknown
  end

  defp called(instr) do
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

  defp func_id({mod, fun, arity}), do: InstrId.func_id(mod, fun, arity)

  defp concatenate(parts) do
    Enum.reduce(parts, [[""]], fn variants, acc ->
      for(left <- acc, right <- variants, do: left ++ right) |> cap()
    end)
  end

  defp cap([]), do: unknown()
  defp cap(values) when length(values) > @variants, do: unknown()
  defp cap(values), do: Enum.uniq(values)
  defp unknown, do: [[:unknown]]

  defp safe_document?(parts) do
    parts
    |> merge_literals()
    |> Enum.reduce_while(:text, fn part, state ->
      case fragment(part, state) do
        :unknown -> {:halt, :unknown}
        next -> {:cont, next}
      end
    end) == :text
  end

  defp merge_literals(parts) do
    parts
    |> Enum.reduce([], fn
      text, [prev | rest] when is_binary(text) and is_binary(prev) -> [prev <> text | rest]
      part, acc -> [part | acc]
    end)
    |> Enum.reverse()
  end

  # Sanitizing separate strings cannot prevent a closing tag assembled across
  # their boundary ("<" <> "/script>"). Require literal separation after each
  # JavaScript fragment, including before another interpolation.
  defp fragment(<<first, _::binary>> = text, {:after_string_input, state})
       when first != ?/, do: scan(text, state)

  defp fragment(text, state) when is_binary(text), do: scan(text, state)
  defp fragment(value, :text) when value == :html_text, do: :text

  defp fragment({:javascript, bits}, {:string, quote} = state) do
    required = if quote == ?', do: @single_safe, else: @double_safe
    if Bitwise.band(bits, required) == required, do: {:after_string_input, state}, else: :unknown
  end

  defp fragment(_, _), do: :unknown

  # A deliberately small HTML/JavaScript grammar: complete inert HTML tags and
  # ordinary script statements. Attributes, comments, regexp literals, template
  # strings and malformed markup remain unknown, rather than borrowing an
  # escaping guarantee from a different parser context.
  defp scan("", state), do: state

  defp scan("<" <> _ = text, :text) do
    if Regex.match?(~r/\A<script>/i, text) do
      scan(binary_part(text, 8, byte_size(text) - 8), :script)
    else
      case Regex.run(
             ~r/\A<\/?(?:html|head|body|title|div|p|pre|code|b|strong|mark|em|i|span|h[1-6])\s*>/i,
             text
           ) do
        [tag] -> scan(binary_part(text, byte_size(tag), byte_size(text) - byte_size(tag)), :text)
        _ -> :unknown
      end
    end
  end

  defp scan(<<_, rest::binary>>, :text), do: scan(rest, :text)

  defp scan("<" <> _ = text, :script) do
    if Regex.match?(~r/\A<\/script\s*>/i, text) do
      [tag] = Regex.run(~r/\A<\/script\s*>/i, text)
      scan(binary_part(text, byte_size(tag), byte_size(text) - byte_size(tag)), :text)
    else
      :unknown
    end
  end

  defp scan(<<quote, rest::binary>>, :script) when quote in [?', ?"],
    do: scan(rest, {:string, quote})

  defp scan(<<char, rest::binary>>, :script)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in [
                32,
                9,
                10,
                13,
                ?_,
                ?$,
                ?=,
                ?;,
                ?,,
                ?.,
                ?(,
                ?),
                ?[,
                ?],
                ?{,
                ?},
                ?+,
                ?-,
                ?*,
                ?!,
                ?:,
                ??,
                ?>,
                ?&,
                ?|,
                ?%
              ],
       do: scan(rest, :script)

  defp scan(<<quote, rest::binary>>, {:string, quote}), do: scan(rest, :script)

  defp scan(<<92, char, rest::binary>>, {:string, quote}) when char not in [?<, 10, 13],
    do: scan(rest, {:string, quote})

  defp scan(<<char, rest::binary>>, {:string, quote}) when char not in [?<, 92, 10, 13],
    do: scan(rest, {:string, quote})

  defp scan(_, _), do: :unknown
end
