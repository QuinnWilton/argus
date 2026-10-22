defmodule Argus.Extractors.VerificationGateTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.VerificationGate

  defp gated(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [VerificationGate])

    for [_id, func] <- Map.get(facts, :verification_gated, []),
        do: func |> String.split(":") |> List.last()
  end

  test "a decode reached only on a verification's accepting edge is gated" do
    assert gated([Argus.Test.Soundness.G10.SignatureGate]) |> Enum.sort() ==
             ["decode_constant/1", "decode_eq/3", "decode_gated/2", "decode_verify/3"]
  end

  test "a verdict a case selects on gates its true arm, and a decode beside it does not" do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.VerificationGateTest.Cases do
        def by_case(data, sig, key) do
          case :crypto.verify(:rsa, :sha256, data, sig, key) do
            true -> :erlang.binary_to_term(data)
            false -> :error
          end
        end

        def after_check(data, sig, key) do
          _ = :crypto.verify(:rsa, :sha256, data, sig, key)
          :erlang.binary_to_term(data)
        end
      end
      """)

    assert gated([bin]) == ["by_case/3"]
  end
end
