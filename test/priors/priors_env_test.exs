defmodule Argus.PriorsEnvTest do
  # Sync on purpose: the key is read from the VM-wide environment, and a
  # concurrent test asking a live oracle would see it vanish.
  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.Secret, as: S

  @mods [S.Exposed, S.PartlyRedacted, S.Redacted, S.Ordinary, S.Heuristic]

  test "live without a key fails at configuration, before extracting" do
    key = System.get_env("TYPESAFE_API_KEY")
    System.delete_env("TYPESAFE_API_KEY")

    try do
      assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn -> Argus.Config.load(priors: :live) end

      assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn ->
        Argus.Findings.run(@mods, analyses: [:exposure], priors: :live)
      end
    after
      if key, do: System.put_env("TYPESAFE_API_KEY", key)
    end
  end
end
