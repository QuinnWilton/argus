# Soundness fixtures (review 2): each shape must keep the severity its
# test states. Probes of the review and adversarial neighbours.
# credo:disable-for-this-file
# 8ebfbd53: every module under `Mix.` is tooling ("a release does not ship
# Mix"). akkoma ships its Mix.Tasks.Pleroma.* in the release and its
# pleroma_ctl runs them INSIDE the live node:
#   pleroma rpc 'Pleroma.ReleaseTasks.run("user new ...")'
# -> Pleroma.ReleaseTasks.run/1 -> Mix.Tasks.Pleroma.<Task>.run(args).
# The tooling prior's own criteria call "the admin or command-line commands
# an operator runs against the live system" the product.
defmodule Argus.Test.Soundness.G9.Quota do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:probe_g9_quota, [:named_table, :public, :set])
    {:ok, nil}
  end

  # The live system's own writer.
  def charge(user, n) do
    case :ets.lookup(:probe_g9_quota, user) do
      [{^user, used}] -> :ets.insert(:probe_g9_quota, {user, used + n})
      [] -> :ets.insert(:probe_g9_quota, {user, n})
    end
  end
end

defmodule Mix.Tasks.Soundness.G9.Quota do
  # An operator task pleroma_ctl-style runs against the live node: a
  # lookup-then-insert racing the live writers above.
  def run([user, extra]) do
    add = String.to_integer(extra)

    case :ets.lookup(:probe_g9_quota, user) do
      [{^user, used}] -> :ets.insert(:probe_g9_quota, {user, used - add})
      [] -> :ets.insert(:probe_g9_quota, {user, 0})
    end
  end
end

defmodule Argus.Test.Soundness.G9.ReleaseTasks do
  # The product entry an operator's rpc calls.
  def run(args), do: Mix.Tasks.Soundness.G9.Quota.run(String.split(args))
end
