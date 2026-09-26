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

  @owners ~w(HelperOwner ModulesOwner HelperTempOwner EnvOwner AppendedOwner OptionalOwner
             RejectedOwner OverriddenOwner RuntimeMapOwner RuntimeRestartOwner TransientOwner)a

  @modules [
             :spec_helper_sup,
             Specs.AppendedApp,
             Specs.RejectSup,
             Specs.OverrideSup,
             Specs.RestartSup,
             Specs.MapOwner,
             Specs.Remote,
             Specs.ProvisionerLike,
             Specs.PermanentStopper
           ] ++ Enum.map(@owners, &Module.concat(Specs, &1))

  setup_all do
    dies =
      for {:warning, "ETS table dies with its owner", {mod, _f, _a}} <- fired(@modules, :ets),
          uniq: true,
          do: mod

    %{dies: dies}
  end

  # A restart the spec says is not permanent: handed to a helper, stated
  # by a Supervisor.child_spec/2 override, or by the shorthand's own
  # child_spec/1 (`use GenServer, restart: :transient`).
  for owner <- ~w(HelperTempOwner OverriddenOwner TransientOwner)a do
    test "#{owner}'s table still dies with it: its spec's restart is not permanent", %{dies: dies} do
      assert Module.concat(Specs, unquote(owner)) in dies
    end
  end

  # A module or a restart the extractor cannot read names no child.
  for owner <- ~w(EnvOwner RuntimeRestartOwner)a do
    test "#{owner}'s table still dies with it: its spec is one the extractor cannot read", %{
      dies: dies
    } do
      assert Module.concat(Specs, unquote(owner)) in dies
    end
  end

  test "each shape's permanent child is excused", %{dies: dies} do
    # A helper's tuple spec, a modules list built with ++, a list joined
    # with ++ (a conditional part's child included), a Mod.child_spec/1
    # call, Enum.reject(&is_nil/1), a runtime map with the default restart.
    excused =
      ~w(HelperOwner ModulesOwner AppendedOwner OptionalOwner RejectedOwner RuntimeMapOwner
         MapOwner)a

    for owner <- excused, do: refute(Module.concat(Specs, owner) in dies, inspect(owner))
  end
end
