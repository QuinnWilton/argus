defmodule Argus.Soundness.SupervisionTest do
  @moduledoc """
  The permanent-child excuse of "ETS table dies with its owner" rests on
  the supervision extractor naming no child it cannot read. The
  supervision round (the ETS rows round found 8 of 12 sampled rows were
  permanent children the extractor missed) reads child specs a helper
  builds, a `start_child` adds, a `++` joins and a `Mod.child_spec/1`
  call names; each shape has an owner it now excuses, and adversarial
  neighbours whose owner must stay reported: a restart the spec says is
  not permanent, one it takes from a call, and a module it takes from a
  call or from the function's parameter (test/fixtures/
  supervision_specs_fixture.ex, spec_helper_sup.erl, spec_start_child.erl).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  @owners ~w(HelperOwner ModulesOwner HelperTempOwner EnvOwner AddedOwner AddedMapOwner
             AddedTempOwner AddedParamOwner AddedDynOwner AppendedOwner OptionalOwner
             RejectedOwner OverriddenOwner RuntimeMapOwner RuntimeRestartOwner StartedOwner
             StartedTempOwner DynamicOwner TransientOwner StartedShorthandTempOwner
             OverriddenPermanentOwner)a

  @modules [
             :spec_helper_sup,
             :spec_start_child,
             Specs.AppendedApp,
             Specs.RejectSup,
             Specs.OverrideSup,
             Specs.RestartSup,
             Specs.Starter,
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
  # by a start_child's spec, by a Supervisor.child_spec/2 override (over
  # the module's own `restart: :permanent` too), by a map, or by the
  # shorthand's own child_spec/1 (`use GenServer, restart: :transient`),
  # in a child list or a start_child.
  for owner <-
        ~w(HelperTempOwner AddedTempOwner OverriddenOwner StartedTempOwner TransientOwner
           StartedShorthandTempOwner OverriddenPermanentOwner)a do
    test "#{owner}'s table still dies with it: its spec's restart is not permanent", %{dies: dies} do
      assert Module.concat(Specs, unquote(owner)) in dies
    end
  end

  # A restart or a module the extractor cannot read names no child.
  for owner <- ~w(EnvOwner AddedParamOwner AddedDynOwner RuntimeRestartOwner)a do
    test "#{owner}'s table still dies with it: its spec is one the extractor cannot read", %{
      dies: dies
    } do
      assert Module.concat(Specs, unquote(owner)) in dies
    end
  end

  test "each shape's permanent child is excused", %{dies: dies} do
    excused =
      ~w(HelperOwner ModulesOwner AddedOwner AddedMapOwner AppendedOwner OptionalOwner
         RejectedOwner RuntimeMapOwner StartedOwner DynamicOwner)a

    for owner <- excused, do: refute(Module.concat(Specs, owner) in dies, inspect(owner))
    refute Specs.MapOwner in dies
  end
end
