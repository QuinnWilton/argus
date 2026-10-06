defmodule Argus.Test.Fixtures.LiveEndpoint do
  @moduledoc """
  A Phoenix endpoint's socket table as `socket/3` compiles it: one
  literal, read by `Argus.Extractors.Endpoint`. No other fixture
  switches a transport on.
  """

  def __sockets__, do: [{"/live", Phoenix.LiveView.Socket, [websocket: [], longpoll: []]}]
end
