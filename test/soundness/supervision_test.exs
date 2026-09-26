defmodule Argus.Soundness.SupervisionTest do
  @moduledoc """
  The permanent-child excuse of "ETS table dies with its owner" rests on
  the supervision extractor naming no child it cannot read, with the
  restart the child runs under. The supervision round (the ETS rows round
  found 8 of 12 sampled rows were permanent children the extractor
  missed) reads more specs; each shape has an owner it now excuses, and
  adversarial neighbours whose owner must stay reported: a restart the
  spec says is not permanent, one it takes from a call, and a module it
  takes from a call or from the function's parameter
  (test/fixtures/supervision_specs_fixture.ex, test/fixtures/erl).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  @modules [Specs.RestartSup, Specs.TransientOwner, Specs.ProvisionerLike, Specs.PermanentStopper]

  setup_all do
    dies =
      for {:warning, "ETS table dies with its owner", {mod, _f, _a}} <- fired(@modules, :ets),
          uniq: true,
          do: mod

    %{dies: dies}
  end

  # A shorthand runs under its own child_spec/1's restart: `use
  # GenServer, restart: :transient` is not restarted after a normal stop.
  test "a shorthand whose own child_spec/1 says :transient is no excuse", %{dies: dies} do
    assert Specs.TransientOwner in dies
  end
end
