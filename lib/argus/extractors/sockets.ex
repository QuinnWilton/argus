defmodule Argus.Extractors.Sockets do
  @moduledoc """
  TCP and TLS sockets: where a process makes one active, and where it
  waits on one with no deadline.

  An active socket (`active: true`, `:once` or a count) delivers what it
  receives as messages to the process that controls it — the one that
  connected it, unless it was handed on — and its end the same way:
  `{:tcp_closed, socket}` or `{:ssl_closed, socket}` arrives however the
  connection goes, a peer that closes, a network that drops, a TLS alert.
  `:gen_tcp.connect/3,4` and `:ssl.connect/3,4` make a socket active
  unless their options say otherwise; `:inet.setopts/2` and
  `:ssl.setopts/2` (and a transport module's `setopts/2` called through a
  variable, `transport.setopts(socket, active: :once)`) make it active
  again. Where the options are the enclosing function's parameter, a
  wrapper of the program's own (`Socket.setopts(s, [:binary, active:
  true])`), the call that hands the literal list down says the mode.

  A passive socket is read with `recv`, and a socket call whose arity
  leaves out the timeout waits with `:infinity`: `:gen_tcp.recv/2`,
  `:gen_tcp.connect/3` (bounded only by the operating system's connect
  timeout, minutes on Linux), `:ssl.recv/2`, `:ssl.connect/2,3`,
  `:ssl.handshake/1` and `:ssl.handshake/2` with options.

  Only literal option lists are read. A list built at runtime is
  `"dynamic"`, and a rule treats it as saying nothing: a mode the
  bytecode does not show is no evidence that the socket is active.

  ## Emitted facts

  - `socket_active(id, func, transport, mode, param)` — the call at `id`
    opens a socket or sets its options. `transport` is `"tcp"`, `"ssl"`,
    `"inet"` (`:inet.setopts/2`, a TCP or a UDP socket) or `"any"` (a
    `setopts/2` through a module held in a variable). `mode` is the
    `:active` value the literal options give (`"true"`, `"once"`, `"n"`
    for a positive count, `"false"`), `"default"` for a connect whose
    literal options leave it out (active: true), `"unset"` for a setopts
    whose literal options leave it out (unchanged), `"param"` when the
    options are the function's parameter `param` (0-based; -1 otherwise),
    or `"dynamic"`.
  - `socket_opts_arg(id, caller, callee, pos, mode)` — the call at `id`
    hands `callee` a literal option list with an `:active` entry of
    `mode`, at argument `pos`: what a wrapper's `"param"` row resolves to.
  - `socket_wait(id, func, api, timeout, param)` — a blocking socket call:
    `timeout` is `"infinity"` (the arity leaves it out, or `:infinity` is
    passed), `"bounded"` (a literal count), `"param"` (the function's
    parameter `param`) or `"dynamic"`.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  # Calls that open or set the options of a socket: {transport, what,
  # options position}. `:open` calls default to active: true.
  @activations %{
    {:gen_tcp, :connect, 3} => {"tcp", :open, 2},
    {:gen_tcp, :connect, 4} => {"tcp", :open, 2},
    {:ssl, :connect, 2} => {"ssl", :open, 1},
    {:ssl, :connect, 3} => {"ssl", :open, :connect3},
    {:ssl, :connect, 4} => {"ssl", :open, 2},
    {:inet, :setopts, 2} => {"inet", :setopts, 1},
    {:ssl, :setopts, 2} => {"ssl", :setopts, 1},
    {:ranch_tcp, :setopts, 2} => {"tcp", :setopts, 1},
    {:ranch_ssl, :setopts, 2} => {"ssl", :setopts, 1}
  }

  # Blocking socket calls: the timeout's argument position, or :infinity
  # when the arity leaves it out.
  @waits %{
    {:gen_tcp, :recv, 2} => :infinity,
    {:gen_tcp, :recv, 3} => 2,
    {:gen_tcp, :connect, 3} => :infinity,
    {:gen_tcp, :connect, 4} => 3,
    {:ssl, :recv, 2} => :infinity,
    {:ssl, :recv, 3} => 2,
    {:ssl, :connect, 2} => :infinity,
    {:ssl, :connect, 3} => :connect3,
    {:ssl, :connect, 4} => 3,
    {:ssl, :handshake, 1} => :infinity,
    {:ssl, :handshake, 2} => :handshake2,
    {:ssl, :handshake, 3} => 2
  }

  @impl true
  def relations, do: [:socket_active, :socket_opts_arg, :socket_wait]

  @impl true
  @doc false
  def candidate_instructions?(instructions) do
    holds_active_literal?(instructions) or
      Enum.any?(instructions, fn
        {:apply, 2} ->
          true

        {:apply_last, 2, _} ->
          true

        instruction ->
          case Argus.Extractor.Helpers.match_remote_call(instruction) do
            {:ok, m, f, a} ->
              Map.has_key?(@activations, {m, f, a}) or Map.has_key?(@waits, {m, f, a})

            :none ->
              false
          end
      end)
  end

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions} = module_data) do
    sites = CallSites.for_module(module_data)

    facts =
      Enum.reduce(sites, %{}, fn site, acc ->
        acc
        |> activation(site)
        |> wait(site)
      end)

    facts
    |> transport_applies(mod, functions)
    |> handed_options(sites)
  end

  # ── Activation ─────────────────────────────────────────────────────

  defp activation(facts, %{remote?: true, mfa: mfa} = site) do
    case Map.fetch(@activations, mfa) do
      {:ok, {transport, what, pos}} ->
        emit_active(facts, site, transport, what, options_position(site, pos))

      :error ->
        facts
    end
  end

  defp activation(facts, _site), do: facts

  defp emit_active(facts, site, transport, what, pos) do
    {mode, param} = mode_at(site.instrs, site.idx, pos, what)
    id = InstrId.mint(site.func_id, site.idx)
    add_fact(facts, :socket_active, [id, site.func_id, transport, mode, param])
  end

  # The mode the options at `pos` give, and the parameter they come from.
  defp mode_at(_instrs, _idx, nil, _what), do: {"dynamic", "-1"}

  defp mode_at(instrs, idx, pos, what) do
    case Resolve.value_at(instrs, idx, {:x, pos}) do
      {:literal, opts} when is_list(opts) -> {list_mode(opts, what), "-1"}
      {:arg, n} -> {"param", Integer.to_string(n)}
      _ -> {"dynamic", "-1"}
    end
  end

  # `:ssl.connect/3` is `connect(host, port, options)` or `connect(socket,
  # options, timeout)`. A literal third argument says which, or failing
  # that a literal second one; failing both it is the first form, the
  # common one, whose options are then what a caller hands down.
  defp options_position(site, :connect3) do
    case connect3_form(site) do
      :upgrade -> 1
      _host_or_unknown -> 2
    end
  end

  defp options_position(_site, pos), do: pos

  defp connect3_form(site) do
    case {Resolve.value_at(site.instrs, site.idx, {:x, 2}),
          Resolve.value_at(site.instrs, site.idx, {:x, 1})} do
      {{:literal, opts}, _} when is_list(opts) -> :host
      {{:literal, timeout}, _} when is_integer(timeout) or timeout == :infinity -> :upgrade
      {_, {:literal, opts}} when is_list(opts) -> :upgrade
      {_, {:literal, port}} when is_integer(port) -> :host
      _ -> :unknown
    end
  end

  defp list_at?(site, pos),
    do: match?({:literal, l} when is_list(l), Resolve.value_at(site.instrs, site.idx, {:x, pos}))

  # The last `:active` entry wins, as the socket applies its options in
  # order. A part of the list the bytecode does not show, with no entry
  # after it, says nothing.
  defp list_mode(opts, what) do
    case active_entry(opts) do
      {:ok, value} -> value_mode(value)
      :none when what == :open -> "default"
      :none -> "unset"
    end
  end

  defp active_entry(elements) do
    elements
    |> Enum.reverse()
    |> Enum.find_value(:none, fn
      {:active, value} -> {:ok, value}
      :dynamic -> :unknown
      _ -> nil
    end)
    |> case do
      :unknown -> {:ok, :dynamic}
      other -> other
    end
  end

  defp value_mode(true), do: "true"
  defp value_mode(:once), do: "once"
  defp value_mode(false), do: "false"
  defp value_mode(n) when is_integer(n) and n > 0, do: "n"
  defp value_mode(n) when is_integer(n), do: "false"
  defp value_mode(_), do: "dynamic"

  # `transport.setopts(socket, opts)`, the module in a variable, compiles
  # to an apply of `setopts/2`: the transport is whichever the process
  # opened.
  defp transport_applies(facts, mod, functions) do
    for {:function, name, arity, _entry, instrs} <- functions,
        func_id = InstrId.func_id(mod, name, arity),
        {instr, idx} <- Enum.with_index(instrs),
        applies_setopts?(instrs, idx, instr),
        reduce: facts do
      acc ->
        {mode, param} = mode_at(instrs, idx, 1, :setopts)
        id = InstrId.mint(func_id, idx)
        add_fact(acc, :socket_active, [id, func_id, "any", mode, param])
    end
  end

  defp applies_setopts?(instrs, idx, {:apply, 2}), do: setopts_named?(instrs, idx)
  defp applies_setopts?(instrs, idx, {:apply_last, 2, _}), do: setopts_named?(instrs, idx)
  defp applies_setopts?(_instrs, _idx, _instr), do: false

  defp setopts_named?(instrs, idx),
    do: Resolve.resolve_register(instrs, idx, {:x, 3}) == {:ok, :setopts}

  # ── Options handed down ────────────────────────────────────────────

  # A literal option list with an `:active` entry handed to any call. Only
  # a function holding such a literal is read at all.
  defp handed_options(facts, sites) do
    sites
    |> Enum.group_by(& &1.func_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(facts, fn {_func_id, [%{instrs: instrs} | _] = calls}, acc ->
      if holds_active_literal?(instrs), do: emit_handed(acc, calls), else: acc
    end)
  end

  defp holds_active_literal?(instrs) do
    Enum.any?(instrs, fn instr ->
      Terms.mentions?(instr, fn
        {:literal, value} -> Terms.value_contains?(value, &match?({:active, _}, &1))
        _ -> false
      end)
    end)
  end

  defp emit_handed(facts, calls) do
    for %{mfa: {m, f, a}} = site <- calls,
        not Map.has_key?(@activations, {m, f, a}),
        pos <- 0..(a - 1)//1,
        {:literal, opts} when is_list(opts) <-
          [Resolve.value_at(site.instrs, site.idx, {:x, pos})],
        {:ok, value} <- [active_entry(opts)],
        reduce: facts do
      acc ->
        add_fact(acc, :socket_opts_arg, [
          InstrId.mint(site.func_id, site.idx),
          site.func_id,
          InstrId.func_id(m, f, a),
          Integer.to_string(pos),
          value_mode(value)
        ])
    end
  end

  # ── Waits ──────────────────────────────────────────────────────────

  defp wait(facts, %{remote?: true, mfa: {m, f, a} = mfa} = site) do
    case Map.fetch(@waits, mfa) do
      {:ok, pos} ->
        {timeout, param} = timeout_at(site, pos)
        api = "#{inspect(m)}.#{f}/#{a}"
        id = InstrId.mint(site.func_id, site.idx)
        add_fact(facts, :socket_wait, [id, site.func_id, api, timeout, param])

      :error ->
        facts
    end
  end

  defp wait(facts, _site), do: facts

  defp timeout_at(_site, :infinity), do: {"infinity", "-1"}

  # `:ssl.connect(host, port, options)` waits forever; `connect(socket,
  # options, timeout)` as long as its third argument says. Which form a
  # call is, when neither argument is a literal, is not guessed.
  defp timeout_at(site, :connect3) do
    case connect3_form(site) do
      :host -> {"infinity", "-1"}
      :upgrade -> timeout_at(site, 2)
      :unknown -> {"dynamic", "-1"}
    end
  end

  # `:ssl.handshake(socket, options)` waits forever; `handshake(socket,
  # timeout)` as long as it says.
  defp timeout_at(site, :handshake2) do
    if list_at?(site, 1), do: {"infinity", "-1"}, else: timeout_at(site, 1)
  end

  defp timeout_at(site, pos) do
    case Resolve.value_at(site.instrs, site.idx, {:x, pos}) do
      {:literal, :infinity} -> {"infinity", "-1"}
      {:literal, n} when is_integer(n) -> {"bounded", "-1"}
      {:arg, n} -> {"param", Integer.to_string(n)}
      _ -> {"dynamic", "-1"}
    end
  end
end
