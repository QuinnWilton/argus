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

  ## Emitted facts

  - `tls_verification(id, func, setting)` — `"none"` | `"peer"` | `"absent"`
  - `tls_connect(id, func, api, opts)` — a TLS connect and how its options
    were supplied: `"literal"` | `"dynamic"`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3, match_remote_call: 1]

  # Calls that establish a TLS session and take an option list. The arity
  # here is the position of the options argument, zero-based.
  @tls_connects %{
    {:ssl, :connect, 3} => 2,
    {:ssl, :connect, 4} => 2,
    {:ssl, :handshake, 2} => 1,
    {:ssl, :handshake, 3} => 1,
    {:ssl, :listen, 2} => 1
  }

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
    end)
  end

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
      {:move, {:literal, opts}, ^register} when is_list(opts) -> {:ok, opts}
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

  defp mentions_atom?(term, atom) when is_tuple(term),
    do: term |> Tuple.to_list() |> mentions_atom?(atom)

  defp mentions_atom?(term, atom) when is_list(term),
    do: Enum.any?(term, &mentions_atom?(&1, atom))

  defp mentions_atom?(atom, atom) when is_atom(atom), do: true
  defp mentions_atom?(_term, _atom), do: false
end
