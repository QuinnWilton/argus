# Atoms made of the application's configuration (ParamFlow's `config`
# origin): host config is the host's code, not a request's data. Shaped
# like phoenix_kit_ai's Images.Operations, whose `to_atom/1` converts the
# names in `Application.get_env(:phoenix_kit_ai, :image_operations)`, and
# which a LiveView's handle_event reaches on calls.
#
# Behaviours are bare `@behaviour` attributes, as in the Taint fixtures.

defmodule Argus.Test.Fixtures.ContractConfigOps do
  @moduledoc false

  def all do
    case Application.get_env(:argus_fixture, :operations, %{}) do
      extra when is_map(extra) -> normalize_specs(extra)
      _ -> %{}
    end
  end

  def names, do: Map.keys(all())

  defp normalize_specs(extra) do
    Map.new(extra, fn {name, spec} ->
      spec = Map.new(spec, fn {k, v} -> {to_atom(k), v} end)
      {to_atom(name), spec}
    end)
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)
end

defmodule Argus.Test.Fixtures.ContractConfigLive do
  @moduledoc false
  @behaviour Phoenix.LiveView

  alias Argus.Test.Fixtures.ContractConfigOps

  def handle_event("operations", _params, socket),
    do: {:noreply, Map.put(socket, :operations, ContractConfigOps.names())}
end

defmodule Argus.Test.Fixtures.ContractConfigMixed do
  @moduledoc false
  @behaviour Phoenix.LiveView

  # The config prefix and the request's own name: request data reaches the
  # sink, a flow.
  def handle_event("pick", %{"op" => op}, socket),
    do: {:noreply, Map.put(socket, :op, operation(op))}

  defp operation(op),
    do: String.to_atom(Application.get_env(:argus_fixture, :prefix, "op_") <> op)
end

defmodule Argus.Test.Fixtures.ContractConfigStore do
  @moduledoc false

  def load(id), do: Process.get(id)
end

defmodule Argus.Test.Fixtures.ContractConfigStored do
  @moduledoc false
  @behaviour Phoenix.LiveView

  alias Argus.Test.Fixtures.ContractConfigStore

  # The config prefix and a stored record's field: not config alone, so
  # the path is still reported.
  def handle_params(_params, _uri, socket) do
    {:noreply, Map.put(socket, :kind, kind(ContractConfigStore.load(:current)))}
  end

  defp kind(record) do
    String.to_atom(Application.get_env(:argus_fixture, :prefix, "") <> record.kind)
  end
end
