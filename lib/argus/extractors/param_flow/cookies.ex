defmodule Argus.Extractors.ParamFlow.Cookies do
  @moduledoc """
  The cookies a request's conn holds that the server wrote: those
  `Plug.Conn.fetch_cookies/2` was told to verify.

  `fetch_cookies(conn, signed: ["session"], encrypted: ["token"])` puts
  every cookie of the request in `conn.cookies`, and checks the MAC of
  the ones its options name: `conn.cookies["session"]` is what the server
  signed (or `nil`), while `conn.cookies["prefs"]` is whatever bytes the
  client sent. The conn it returns carries the request's data, as any
  conn does; a read of a verified cookie out of it does not.

  A read is the server's when the map it reads is the `cookies` field of
  the conn one `fetch_cookies/2` call in the same function returned, the
  key is a literal, and that call's literal options list the key under
  `signed:` or `encrypted:`. Every other read carries the request's data:
  a key not listed, a conn from elsewhere (a parameter, a helper), options
  built at runtime, and `req_cookies`, which holds the raw values of the
  signed ones too. The walk follows the writes that reach each register
  (`Argus.Instr.Reaching`), so a join of two conns reads as the server's
  only when both are.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  # A lookup of a map under a key: {map position, key position}.
  @lookups %{
    {Access, :get, 2} => {0, 1},
    {Access, :get, 3} => {0, 1},
    {Map, :get, 2} => {0, 1},
    {Map, :get, 3} => {0, 1},
    {Map, :fetch, 2} => {0, 1},
    {Map, :fetch!, 2} => {0, 1},
    {:maps, :get, 2} => {1, 0},
    {:maps, :get, 3} => {1, 0},
    {:maps, :find, 2} => {1, 0}
  }

  @doc """
  The writes that read a verified cookie: `{instr_id, register}` pairs,
  the register spelled as the typed facts spell it (`"x0"`).
  """
  @spec server_writes(Argus.Extractor.module_data()) :: MapSet.t({InstrId.t(), String.t()})
  def server_writes(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        Enum.any?(instrs, &fetch_cookies?/1),
        func_id = Normalize.func_id(mod, name, arity),
        {instr, idx} <- Enum.with_index(instrs),
        reg <- writes(instrs, instr, idx),
        {:ok, id} = InstrId.parse(InstrId.mint(func_id, idx)),
        into: MapSet.new(),
        do: {id, reg}
  end

  def server_writes(_module_data), do: MapSet.new()

  defp fetch_cookies?(instr),
    do: match?({:ok, Plug.Conn, :fetch_cookies, 2}, Helpers.match_remote_call(instr))

  # A lookup's result (a call that returns here: its result is in x0),
  # or the registers a map match reads under a verified key.
  defp writes(instrs, {:call_ext, _, _} = instr, idx) do
    with {:ok, m, f, a} <- Helpers.match_remote_call(instr),
         {:ok, {map_pos, key_pos}} <- Map.fetch(@lookups, {m, f, a}),
         {:ok, key} <- literal(instrs, idx, {:x, key_pos}),
         {:ok, keys} <- verified(instrs, idx, {:x, map_pos}),
         true <- key in keys do
      ["x0"]
    else
      _ -> []
    end
  end

  defp writes(instrs, {:get_map_elements, _fail, src, {:list, pairs}}, idx) do
    case verified(instrs, idx, src) do
      {:ok, keys} ->
        for [key, dst] <- Enum.chunk_every(pairs, 2),
            literal_key(key) in keys,
            spelled = spell(dst),
            spelled != nil,
            do: spelled

      :none ->
        []
    end
  end

  defp writes(_instrs, _instr, _idx), do: []

  # The keys verified in the cookies map `reg` holds at `idx`: the field
  # `cookies` of a conn fetch_cookies/2 returned, on every way in.
  #
  # `conn.cookies` compiles to a fast path, a map match, joined with a
  # slow one, `:elixir_erl_pass.no_parens_remote(conn, :cookies)`, whose
  # `{:ok, value}` answer is taken apart for the value.
  defp verified(instrs, idx, reg) do
    agree(instrs, idx, reg, fn
      {at, {:get_map_elements, _fail, src, {:list, pairs}}, dst} ->
        if key_of(pairs, dst) == :cookies, do: fetched(instrs, at, src), else: :none

      {at, {:get_tuple_element, src, 1, _dst}, _reg} ->
        agree(instrs, at, src, &cookies_field(instrs, &1))

      writer ->
        cookies_field(instrs, writer)
    end)
  end

  defp cookies_field(instrs, {at, instr, _reg}) do
    if Helpers.match_remote_call(instr) == {:ok, :elixir_erl_pass, :no_parens_remote, 2} and
         literal(instrs, at, {:x, 1}) == {:ok, :cookies},
       do: fetched(instrs, at, {:x, 0}),
       else: :none
  end

  # The key a get_map_elements pair reads into `dst`.
  defp key_of(pairs, dst) do
    Enum.find_value(Enum.chunk_every(pairs, 2), :none, fn [key, d] ->
      if Instr.register(d) == dst, do: literal_key(key)
    end)
  end

  # The conn `reg` holds at `idx` is fetch_cookies/2's answer on every way
  # in: the keys its literal options verify.
  defp fetched(instrs, idx, reg) do
    agree(instrs, idx, reg, fn {at, instr, _dst} ->
      with {:ok, Plug.Conn, :fetch_cookies, 2} <- Helpers.match_remote_call(instr),
           {:ok, opts} when is_list(opts) <- literal(instrs, at, {:x, 1}),
           true <- Keyword.keyword?(opts) do
        {:ok, names(opts, :signed) ++ names(opts, :encrypted)}
      else
        _ -> :none
      end
    end)
  end

  defp names(opts, key) do
    case Keyword.get(opts, key, []) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  # The literal a register holds at `idx`, when every write that reaches
  # it moves the same one.
  defp literal(instrs, idx, reg) do
    agree(instrs, idx, reg, fn
      {_at, {:move, src, _}, _dst} ->
        case literal_key(src) do
          :none -> :none
          value -> {:ok, value}
        end

      _writer ->
        :none
    end)
  end

  # The one answer `answer` gives of every write that reaches `reg` at
  # `idx` (copies followed to what they copied; the writer is handed with
  # the register it wrote), or `:none` when a parameter reaches it, no
  # write does, or two answers differ.
  defp agree(instrs, idx, reg, answer) do
    case writers(instrs, idx, Instr.register(reg), %{}) do
      {:ok, [_ | _] = writers} ->
        writers |> Enum.map(answer) |> Enum.uniq() |> one()

      _ ->
        :none
    end
  end

  defp one([{:ok, _} = only]), do: only
  defp one(_answers), do: :none

  defp writers(instrs, idx, reg, seen) do
    if Map.has_key?(seen, {idx, reg}) do
      {:ok, []}
    else
      seen = Map.put(seen, {idx, reg}, true)

      instrs
      |> Reaching.sources(idx, reg)
      |> Enum.reduce_while({:ok, []}, fn
        {:param, _}, _acc ->
          {:halt, :none}

        at, {:ok, acc} ->
          instr = Reaching.at(instrs, at)

          case Instr.copy_source(instr, reg) do
            {kind, _} = source when kind in [:x, :y] ->
              case writers(instrs, at, source, seen) do
                {:ok, more} -> {:cont, {:ok, more ++ acc}}
                :none -> {:halt, :none}
              end

            _ ->
              {:cont, {:ok, [{at, instr, reg} | acc]}}
          end
      end)
    end
  end

  defp literal_key({:atom, a}), do: a
  defp literal_key({:literal, v}), do: v
  defp literal_key({:integer, i}), do: i
  defp literal_key(nil), do: []
  defp literal_key(_operand), do: :none

  defp spell(operand) do
    case Instr.register(operand) do
      {kind, n} when kind in [:x, :y] -> "#{kind}#{n}"
      _ -> nil
    end
  end
end
