defmodule Argus.Extractors.Tls do
  @moduledoc """
  TLS peer verification, where it is disabled and where it is left to the
  default.

  Encryption without authentication is not security. A TLS connection that
  does not verify the peer's certificate is confidential against a passive
  observer and wide open to anyone who can answer for the host — which is
  the threat TLS exists to address. The failure is silent by construction:
  the connection succeeds, the data is encrypted, and nothing distinguishes
  a verified session from an unverified one at runtime.

  Two shapes, and the second is the reason this is not a grep.

  ## Disabled outright

  `verify: :verify_none` is a literal, so it is exactly detectable — either
  as a bare atom or nested inside a literal option list:

      {:move, {:literal, [verify: :verify_none]}, {:x, 2}}
      {:move, {:atom, :verify_none}, {:x, 2}}

  ## Left to the default

  A TLS connect whose option list is a literal that never mentions `verify`
  takes whatever the library defaults to. Erlang's `:ssl` client verified
  nothing at all before OTP 26, and many wrappers still pass options through
  without supplying one. Reading a call site tells you nothing here — the
  absence is the finding, and absence is what a search cannot look for.

  Only literal option lists are examined. A list built at runtime is
  recorded as unknown rather than guessed at, because a false "this is
  insecure" on a call that configures itself properly is worse than silence.

  ## The server's side

  On a listening or accepting socket `verify: :verify_none` does not
  switch off the check of a server's certificate: it tells the server
  not to ask its clients for one, which is how nearly every server runs.
  A setting is the server's when its value is made, in its function, into
  the options of a server's call — `:ssl.listen/2`, `:ssl.handshake/2,3`
  (the server's side of an accepted socket), a Ranch or Cowboy TLS
  listener, a Plug.Cowboy, Bandit or ThousandIsland server — and goes
  nowhere else: not into a client's connect, a return, a message, a
  field. The options of a listener named only in a supervisor's child
  list are data, not a call, and are not read.

  ## Emitted facts

  - `tls_verification(id, func, setting)` — `"none"` | `"peer"` | `"absent"`
  - `tls_connect(id, func, api, opts)` — a TLS connect and how its options
    were supplied: `"literal"` | `"dynamic"`
  - `tls_server_side(id, func)` — the setting at `id` configures a server:
    the site of a server's call, or a mention whose value is made only
    into the options of one
  """

  @behaviour Argus.Extractor

  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [match_remote_call: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Terms, only: [mentions?: 2, proper_list?: 1, value_contains?: 2]

  # Calls that establish a TLS session and take an option list. The arity
  # here is the position of the options argument, zero-based.
  @tls_connects %{
    {:ssl, :connect, 3} => 2,
    {:ssl, :connect, 4} => 2,
    {:ssl, :handshake, 2} => 1,
    {:ssl, :handshake, 3} => 1,
    {:ssl, :listen, 2} => 1
  }

  # The calls that configure a server, and the position of their options:
  # where `:verify_none` means "do not ask the client for a certificate".
  @server_apis %{
    {:ssl, :listen, 2} => 1,
    {:ssl, :handshake, 2} => 1,
    {:ssl, :handshake, 3} => 1,
    {:ranch, :start_listener, 5} => 2,
    {:ranch, :start_listener, 6} => 3,
    {:ranch, :child_spec, 5} => 2,
    {:ranch, :child_spec, 6} => 3,
    {:cowboy, :start_tls, 3} => 1,
    {Plug.Cowboy, :https, 3} => 2,
    {Plug.Cowboy, :child_spec, 1} => 0,
    {Bandit, :start_link, 1} => 0,
    {Bandit, :child_spec, 1} => 0,
    {ThousandIsland, :start_link, 1} => 0,
    {ThousandIsland, :child_spec, 1} => 0
  }

  # Calls that build an option list of their arguments: a value handed to
  # one is in what it returns.
  @merges MapSet.new([
            {Keyword, :put, 3},
            {Keyword, :put_new, 3},
            {Keyword, :merge, 2},
            {Map, :put, 3},
            {Map, :merge, 2},
            {Enum, :concat, 2},
            {:lists, :append, 2},
            {:lists, :keystore, 4},
            {:erlang, :++, 2},
            {:maps, :put, 3},
            {:maps, :merge, 2}
          ])

  # Instructions that build a value of what they read, or take one apart:
  # a value they read is in what they write.
  @structural [
    :put_list,
    :put_tuple2,
    :put_map_assoc,
    :put_map_exact,
    :update_record,
    :get_list,
    :get_hd,
    :get_tl,
    :get_tuple_element,
    :get_map_elements
  ]

  @impl true
  def relations,
    do: [
      :tls_connect,
      :tls_server_side,
      :tls_verification
    ]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = InstrId.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {instr, idx}, inner ->
        inner
        |> emit_verification(func_id, instr, idx)
        |> emit_connect(func_id, instrs, instr, idx)
      end)
      |> emit_server_side(func_id, instrs)
    end)
  end

  # ── The server's side ──────────────────────────────────────────────

  # A server call's own site, and every `:verify_none` mention whose value
  # is read only where a server call takes its options — through what
  # builds or takes apart a value, and never anywhere else.
  defp emit_server_side(facts, func_id, instrs) do
    indexed = Enum.with_index(instrs)

    servers =
      for {instr, idx} <- indexed,
          {:ok, m, f, a} <- [match_remote_call(instr)],
          {:ok, pos} <- [Map.fetch(@server_apis, {m, f, a})],
          do: {idx, pos}

    mentions =
      for {instr, idx} <- indexed, mentions_atom?(instr, :verify_none), do: idx

    server_sites = Map.new(servers)

    facts =
      Enum.reduce(servers, facts, fn {idx, _pos}, acc ->
        add_fact(acc, :tls_server_side, [InstrId.mint(func_id, idx), func_id])
      end)

    if servers == [] or mentions == [] do
      facts
    else
      mentions
      |> Enum.reject(&Map.has_key?(server_sites, &1))
      |> Enum.filter(&only_server_options?(instrs, indexed, &1, server_sites))
      |> Enum.reduce(facts, fn idx, acc ->
        add_fact(acc, :tls_server_side, [InstrId.mint(func_id, idx), func_id])
      end)
    end
  end

  # Every read of a value made of the mention is a server call's options,
  # a test, or an instruction that builds on it; and one server call reads
  # it, so it goes somewhere.
  defp only_server_options?(instrs, indexed, mention, server_sites) do
    reads =
      for {instr, idx} <- indexed,
          reg <- Instr.uses(instr),
          instrs |> made_of(idx, reg) |> Map.has_key?(mention),
          do: {idx, instr, reg}

    Enum.any?(reads, fn {idx, _instr, reg} -> server_options?(server_sites, idx, reg) end) and
      Enum.all?(reads, fn {idx, instr, reg} ->
        server_options?(server_sites, idx, reg) or passes_on?(instr) or test?(instr)
      end)
  end

  defp server_options?(server_sites, idx, reg) do
    case Map.fetch(server_sites, idx) do
      {:ok, pos} -> Instr.register(reg) == {:x, pos}
      :error -> false
    end
  end

  defp passes_on?(instr), do: structural?(instr) or merge?(instr) or copy?(instr)

  defp test?(instr), do: is_tuple(instr) and elem(instr, 0) == :test

  defp structural?(instr), do: is_tuple(instr) and elem(instr, 0) in @structural

  defp merge?(instr) do
    case match_remote_call(instr) do
      {:ok, m, f, a} -> MapSet.member?(@merges, {m, f, a})
      :none -> false
    end
  end

  defp copy?(instr), do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil))

  # The instructions the value in `reg` before `idx` is made of: the
  # writes that reach it and, through a copy, a structural instruction or
  # a merge, what those read. A map of their indexes: a MapSet threaded
  # through the walk is opaque to dialyzer.
  defp made_of(instrs, idx, reg), do: made_of(instrs, [{idx, Instr.register(reg)}], %{}, %{})

  defp made_of(_instrs, [], _seen, acc), do: acc

  defp made_of(instrs, [{idx, reg} = here | rest], seen, acc) do
    if Map.has_key?(seen, here) or not register?(reg) do
      made_of(instrs, rest, seen, acc)
    else
      {next, acc} =
        instrs
        |> Reaching.sources(idx, reg)
        |> Enum.reduce({rest, acc}, fn
          {:param, _}, state ->
            state

          at, {next, acc} ->
            instr = Reaching.at(instrs, at)

            reads =
              case Instr.copy_source(instr, reg) do
                {kind, _} = source when kind in [:x, :y] -> [source]
                _ -> if structural?(instr) or merge?(instr), do: Instr.uses(instr), else: []
              end

            {Enum.map(reads, &{at, Instr.register(&1)}) ++ next, Map.put(acc, at, true)}
        end)

      made_of(instrs, next, Map.put(seen, here, true), acc)
    end
  end

  defp register?({kind, n}) when kind in [:x, :y] and is_integer(n), do: true
  defp register?(_operand), do: false

  defp emit_verification(facts, func_id, instr, idx) do
    cond do
      mentions_atom?(instr, :verify_none) ->
        add_fact(facts, :tls_verification, [InstrId.mint(func_id, idx), func_id, "none"])

      mentions_atom?(instr, :verify_peer) ->
        add_fact(facts, :tls_verification, [InstrId.mint(func_id, idx), func_id, "peer"])

      true ->
        facts
    end
  end

  defp emit_connect(facts, func_id, instrs, instr, idx) do
    with {:ok, m, f, a} <- match_remote_call(instr),
         {:ok, opts_pos} <- Map.fetch(@tls_connects, {m, f, a}) do
      api = "#{inspect(m)}.#{f}/#{a}"
      id = InstrId.mint(func_id, idx)

      case literal_options(instrs, idx, opts_pos) do
        {:ok, opts} ->
          facts
          |> add_fact(:tls_connect, [id, func_id, api, "literal"])
          |> add_fact(:tls_verification, [id, func_id, verification_of(opts)])

        :dynamic ->
          add_fact(facts, :tls_connect, [id, func_id, api, "dynamic"])
      end
    else
      _ -> facts
    end
  end

  # The most recent literal moved into the option register before the call.
  # Anything else — a register from a function call, a list built at runtime
  # — is dynamic, and dynamic is reported as such rather than guessed at.
  defp literal_options(instrs, call_idx, opts_pos) do
    register = {:x, opts_pos}

    instrs
    |> Enum.take(call_idx)
    |> Enum.reverse()
    |> Enum.find_value(:dynamic, fn
      {:move, {:literal, opts}, ^register} when is_list(opts) -> proper_options(opts)
      {:move, _src, ^register} -> :dynamic
      _ -> false
    end)
  end

  defp verification_of(opts) do
    case Keyword.get(opts, :verify) do
      :verify_none -> "none"
      :verify_peer -> "peer"
      nil -> "absent"
      _ -> "absent"
    end
  end

  # An improper option list is one the call would reject; it names no
  # verification mode.
  defp proper_options(opts), do: if(proper_list?(opts), do: {:ok, opts}, else: :dynamic)

  # The atom as an operand, or anywhere inside a literal operand's value.
  # Every instruction of every function passes through here, so the walk
  # is the improper-safe one: a literal iolist (`["x" | "y"]`) is common.
  defp mentions_atom?(instr, atom) do
    mentions?(instr, fn
      {:literal, value} -> value_contains?(value, &(&1 == atom))
      term -> term == atom
    end)
  end
end
