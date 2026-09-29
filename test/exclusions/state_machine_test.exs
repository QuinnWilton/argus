defmodule Argus.Exclusions.StateMachineTest do
  @moduledoc """
  Regression cases for state-machine exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/erl/excl_state_machine_*.erl.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows

  @delegating [:excl_state_machine_hello, :excl_state_machine_common]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [@delegating, [:excl_state_machine_stuck], [:excl_state_machine_pump]]

  setup_all do
    %{batch: Batch.solve(:state_machine, @batched)}
  end

  # {module, state} of each row of `relation`.
  defp states(%{batch: batch}, set, relation) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)

    for [mod, state] <- Rows.where(results, :state_machine, relation, drop: [:site]),
        do: {mod, state}
  end

  describe "a state with no way out of its own" do
    # state_machine.dl, returns_program_handler: !statem_module(m2, _).
    test "a state whose events another machine module of the program answers for it", ctx do
      assert states(ctx, @delegating, "terminal_without_stop") == []

      assert states(ctx, [:excl_state_machine_stuck], "terminal_without_stop") ==
               [{":excl_state_machine_stuck", "connected"}]
    end

    # state_machine.dl, terminal_without_stop: !initial_state(mod, state).
    test "the initial state, re-entered from a state nothing reaches", ctx do
      assert states(ctx, [:excl_state_machine_pump], "terminal_without_stop") == []

      assert states(ctx, [:excl_state_machine_pump], "unreachable_state") ==
               [{":excl_state_machine_pump", "running"}]
    end
  end
end
