defmodule Argus.Extractors.VerificationGate do
  @moduledoc """
  A deserialization reached only when a cryptographic verification the function
  itself performs succeeds.

  A decode behind such a gate is not wide open: the bytes that reach it carried a
  signature or MAC the function checked against a server-held secret, so only a
  party with that secret can supply bytes that pass. This is weaker than an
  authenticated-payload API (clientlib/verification.dl), whose key management and
  constant-time comparison the library guarantees; a hand-rolled gate leaves the
  secret's strength, the comparison, and whether the gate covers these exact bytes
  unproven. The finding is therefore re-ranked below an ungated decode, never
  dropped (`Argus.Analyses.UnsafeInput`, `secret_gated_decode`).

  ## What counts as a gate

  A branch on the verdict of a recognised constant-time verification, where the
  decode is reached only through the accepting edge (`SecurityValues.edge_covers?`:
  the branch dominates the decode and removing the accepting edge makes the decode
  unreachable). Two verdict shapes:

  - a boolean a signature verify returned (`:crypto.verify/5,6`,
    `:public_key.verify/4,5`), or a constant-time compare (`Plug.Crypto.secure_compare/2`,
    `:crypto.hash_equals/2`) one of whose operands is a MAC or HMAC digest, directly or
    through a `Base` encoding, tested against `true`/`false`; and
  - a MAC or HMAC digest (`:crypto.mac/3,4`, `:crypto.hmac/3,4`) compared for exact
    equality against another value (the supplied digest).

  A constant-time compare of anything else is no gate: a checksum the sender
  computes (`hash_equals(sha256(data), sum)`), or a token compared before decoding
  some other value, says nothing of who wrote the bytes. Whether the MAC's key is
  the server's, and whether it covers the decoded bytes, is not checked.

  A verdict a `case` or an `if` selects on (`select_val`) gates through its truthy
  arm, as a test does. A gate in a different function from the decode is not
  recognised, nor a decode a higher-order call runs on each element
  (`Enum.map(blobs, &:erlang.binary_to_term/1)`, whose site is the higher-order
  call's): the decode keeps its ungated tier, which is sound (no gated decode is
  wrongly dropped, only not yet re-ranked).

  ## Emitted facts

  - `verification_gated(id, func)` — the `binary_to_term` call at `id` in `func` is
    reached only when a verification in `func` succeeds. `id` is minted as
    `Argus.Extractors.ApiCalls` mints `unsafe_deserialization`, so the two join.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  # Boolean-returning signature verifications.
  @verify_apis [
    {:crypto, :verify, 5},
    {:crypto, :verify, 6},
    {:public_key, :verify, 4},
    {:public_key, :verify, 5}
  ]

  # Constant-time comparisons: a verdict only of a MAC digest.
  @compare_apis [
    {Plug.Crypto, :secure_compare, 2},
    {:crypto, :hash_equals, 2}
  ]

  # Encodings a digest goes through before it is compared.
  @encodings [
    {Base, :encode16, 1},
    {Base, :encode16, 2},
    {Base, :encode64, 1},
    {Base, :encode64, 2},
    {Base, :url_encode64, 1},
    {Base, :url_encode64, 2},
    {Base, :decode16!, 1},
    {Base, :decode16!, 2},
    {Base, :decode64!, 1},
    {Base, :decode64!, 2},
    {Base, :url_decode64!, 1},
    {Base, :url_decode64!, 2},
    {:binary, :encode_hex, 1},
    {:binary, :encode_hex, 2},
    {:base64, :encode, 1},
    {:base64, :decode, 1}
  ]

  # Digest producers whose result an equality check compares against the supplied
  # digest: the hand-rolled HMAC gate.
  @mac_apis [
    {:crypto, :mac, 3},
    {:crypto, :mac, 4},
    {:crypto, :hmac, 3},
    {:crypto, :hmac, 4}
  ]

  @decode_apis [
    {:erlang, :binary_to_term, 1},
    {:erlang, :binary_to_term, 2}
  ]

  @impl true
  def relations, do: [:verification_gated]

  @impl true
  def extract(module_data) do
    sites = Enum.group_by(CallSites.for_module(module_data), & &1.func_id)

    module_data.functions
    |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func = InstrId.func_id(module_data.module, name, arity)

      case Map.get(sites, func, []) do
        [] -> facts
        calls -> gated_in(facts, func, calls, module_data, name, arity, instrs)
      end
    end)
    |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
  end

  defp gated_in(facts, func, calls, module_data, name, arity, instrs) do
    decodes = for site <- calls, member?(@decode_apis, site.mfa), do: site.idx
    macs = idx_set(calls, @mac_apis)
    encodings = idx_set(calls, @encodings)

    compares =
      for site <- calls,
          member?(@compare_apis, site.mfa),
          Enum.any?([{:x, 0}, {:x, 1}], &mac_digest?(instrs, site.idx, &1, macs, encodings)),
          into: MapSet.new(),
          do: site.idx

    verdicts = MapSet.union(idx_set(calls, @verify_apis), compares)

    # No decode, or no verdict a gate could be built from: nothing to re-rank.
    if decodes == [] or (MapSet.size(verdicts) == 0 and MapSet.size(macs) == 0) do
      facts
    else
      cfg = SecurityValues.proof_cfg(Helpers.cfg(module_data, name, arity), instrs)
      gates = gate_edges(instrs, verdicts, macs)

      Enum.reduce(decodes, facts, fn at, acc ->
        if gated?(cfg, gates, at),
          do: add_fact(acc, :verification_gated, [InstrId.mint(func, at), func]),
          else: acc
      end)
    end
  end

  defp gated?(nil, _gates, _at), do: false

  defp gated?(cfg, gates, at) do
    Enum.any?(gates, fn {branch_at, edge} ->
      SecurityValues.edge_covers?(cfg, branch_at, edge, at)
    end)
  end

  # The operand at `at` is a MAC digest the function computed, or an encoding of one.
  defp mac_digest?(instrs, at, operand, macs, encodings, depth \\ 4)
  defp mac_digest?(_instrs, _at, _operand, _macs, _encodings, 0), do: false

  defp mac_digest?(instrs, at, operand, macs, encodings, depth) do
    case SecurityValues.identity_at(instrs, at, operand) do
      {:call, c} ->
        MapSet.member?(macs, c) or
          (MapSet.member?(encodings, c) and
             mac_digest?(instrs, c, {:x, 0}, macs, encodings, depth - 1))

      _ ->
        false
    end
  end

  defp idx_set(calls, apis) do
    for site <- calls, member?(apis, site.mfa), into: MapSet.new(), do: site.idx
  end

  defp member?(apis, {mod, fun, arity}), do: Enum.member?(apis, {mod, fun, arity})

  # The accepting edges of every branch that tests a recognised verdict.
  defp gate_edges(instrs, verdicts, macs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, op, _fail, [left, right]}, at}
      when op in [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne] ->
        test_gate(instrs, at, op, left, right, verdicts, macs)

      # `if verified`/`case verified` on a boolean compiles to a select_val on the
      # verdict: the truthy edge accepts. A select_val whose arms are all falsy
      # (false/nil) accepts on its default edge (:select_fail); a `true` arm accepts
      # on its own edge.
      {{:select_val, src, _default, {:list, arms}}, at} ->
        select_gate(instrs, at, src, arms, verdicts)

      _ ->
        []
    end)
  end

  defp select_gate(instrs, at, src, arms, verdicts) do
    if verdict?(SecurityValues.identity_at(instrs, at, src), verdicts) do
      values =
        arms
        |> Enum.chunk_every(2)
        |> Enum.map(fn [literal | _label] ->
          case SecurityValues.identity_at(instrs, at, literal) do
            {:literal, value} -> value
            _ -> :unknown
          end
        end)

      true_edges = for v <- values, v == true, do: {at, {:select_arm, Terms.spell(v)}}

      default_edge =
        if values != [] and Enum.all?(values, &(&1 in [false, nil])),
          do: [{at, :select_fail}],
          else: []

      true_edges ++ default_edge
    else
      []
    end
  end

  defp test_gate(instrs, at, op, left, right, verdicts, macs) do
    li = SecurityValues.identity_at(instrs, at, left)
    ri = SecurityValues.identity_at(instrs, at, right)

    cond do
      # A boolean verdict compared against a boolean literal: `if verified`.
      verdict?(li, verdicts) and boolean(ri) != nil -> [{at, accept_boolean(op, boolean(ri))}]
      verdict?(ri, verdicts) and boolean(li) != nil -> [{at, accept_boolean(op, boolean(li))}]
      # A MAC digest compared for equality against the supplied digest.
      verdict?(li, macs) -> [{at, accept_equality(op)}]
      verdict?(ri, macs) -> [{at, accept_equality(op)}]
      true -> []
    end
  end

  defp verdict?({:call, at}, set), do: MapSet.member?(set, at)
  defp verdict?(_identity, _set), do: false

  defp boolean({:literal, value}) when is_boolean(value), do: value
  defp boolean(_identity), do: nil

  defp eq_op(op) when op in [:is_eq_exact, :is_eq], do: :eq
  defp eq_op(op) when op in [:is_ne_exact, :is_ne], do: :ne

  # The edge on which the verdict is truthy. An equality test's pass (fall-through)
  # edge is taken when the operands are equal; an inequality test's when they differ.
  defp accept_boolean(op, bool) do
    case {eq_op(op), bool} do
      {:eq, true} -> :branch_pass
      {:eq, false} -> :branch_fail
      {:ne, true} -> :branch_fail
      {:ne, false} -> :branch_pass
    end
  end

  # The digest matched the supplied one: the equal edge accepts.
  defp accept_equality(op) do
    case eq_op(op) do
      :eq -> :branch_pass
      :ne -> :branch_fail
    end
  end
end
