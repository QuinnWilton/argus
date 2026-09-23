defmodule Argus.Test.Fixtures.Router do
  @moduledoc """
  What `Phoenix.Router` compiles `__routes__/0` to: one literal list of
  route maps. The route leads to a LiveView whose `handle_params/3` is
  one call from an atom-creation sink.
  """

  def __routes__ do
    [
      %{
        path: "/orders/:field",
        verb: :get,
        plug: Argus.Test.Fixtures.RequestSurface.AdjacentLiveView,
        plug_opts: :index
      }
    ]
  end
end
