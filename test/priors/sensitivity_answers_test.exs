defmodule Argus.Priors.Questions.SensitivityAnswersTest do
  @moduledoc """
  Jev's recorded answers to version 2 for the six schemas behind the
  priors hunt's six warnings. Version 1 called four of those fields
  secrets at 0.9 and above that are not: nerves_hub's `OrgKey.key` (an
  Ed25519 public key), `SharedSecretAuth.key` twice (the key's public id;
  the secret is `secret`) and blockster's `PlatformAccount.credentials_ref`.
  The cassette pins that the fields version 2 was built for stay fixed,
  and that the real secrets beside them still clear `exposure`'s 0.9.

  The requests are rebuilt from the extracted rows, so a change to what
  the question shows the model misses the cassette and fails here: a
  change in wording is a new prompt version and a new recording.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors.{Cache, Driver}
  alias Argus.Priors.Questions.Sensitivity

  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/priors", __DIR__)

  setup %{tmp_dir: dir} do
    {:ok, 7} = Cache.import(dir, Path.join(@fixtures, "sensitivity_v2_hunt.jsonl"))
    {raw, _} = Code.eval_file(Path.join(@fixtures, "hunt_schemas.exs"))

    {:ok, rows, stats} =
      Driver.derive(Sensitivity, Argus.Facts.decode(raw), mode: :cached_only, cache_dir: dir)

    assert %{requests: 7, cached: 7, failed: 0} = stats

    %{
      rows:
        Map.new(rows, fn [_, mod, field, kind, detail, _dp, p] ->
          {{mod, field}, {kind, detail, String.to_integer(p)}}
        end)
    }
  end

  defp secret?({"secret", _detail, p}), do: p >= 900
  defp secret?(_), do: false

  test "the real secrets clear 0.9", %{rows: rows} do
    for field <- [
          {"Sequin.Consumers.NatsSink", ":nkey_seed"},
          {"Sequin.Consumers.NatsSink", ":jwt"},
          {"Sequin.Consumers.NatsSink", ":password"},
          {"Sequin.Consumers.GcpPubsubSink", ":credentials"},
          {"NervesHub.Devices.SharedSecretAuth", ":secret"},
          {"NervesHub.Products.SharedSecretAuth", ":secret"}
        ] do
      assert secret?(rows[field]), "#{inspect(field)}: #{inspect(rows[field])}"
    end
  end

  test "a key's id and a reference to credentials are not secrets", %{rows: rows} do
    for field <- [
          {"NervesHub.Devices.SharedSecretAuth", ":key"},
          {"NervesHub.Products.SharedSecretAuth", ":key"},
          {"BlocksterV2.AdsManager.Schemas.PlatformAccount", ":credentials_ref"}
        ] do
      assert {"none", "secret_reference", _} = rows[field]
    end
  end

  test "a public key stays under exposure's threshold", %{rows: rows} do
    # The model still leans secret on a bare `key` in `OrgKey` (0.83):
    # nothing in the schema says Ed25519 or public. Under 0.9 it adds no
    # finding, which is the point of the threshold.
    refute secret?(rows[{"NervesHub.Accounts.OrgKey", ":key"}])
  end
end
