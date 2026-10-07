defmodule Argus.Soundness.EffectsTest do
  @moduledoc """
  Network I/O a transaction's work reaches through a task keeps its
  error: an awaited task is the transaction's own work, and one it does
  not wait for still sends before the commit. Past such a start only the
  process table's operations are left to the start's own finding
  (soundness review 2, test/fixtures/soundness/effects_fixture.ex).
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  import Argus.Test.Soundness.Case

  setup_all do
    %{sev: severities(modules("effects_fixture.ex"), [:effects])}
  end

  @net "Network I/O inside a transaction"
  @proc "A process operation inside a transaction"

  test "a supervised, awaited or spawned webhook is network I/O in the transaction", %{sev: sev} do
    for mod <- ~w(G8.TxnSupStart G8.TxnSupNolink G8.TxnTaskAwait G8.TxnSupAwait
                  Adv.Txn.RawSpawn Adv.Txn.FunRef Adv.Txn.Helper Adv.Txn.Yield) do
      assert severity(sev, mod, :create, @net) == :error, mod
      assert severity(sev, mod, :create, @proc) == :warning, mod
    end
  end

  test "a spawned pusher's own process operations are the spawn's one finding", %{sev: sev} do
    assert Enum.count(sev, fn {{m, f, t}, _} ->
             m == "Adv.Txn.Streams" and f == :create and t == @proc
           end) ==
             1
  end
end
