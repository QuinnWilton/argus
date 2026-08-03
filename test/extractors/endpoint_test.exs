defmodule Argus.Extractors.EndpointTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Endpoint

  # `socket/3` is a macro, so its options compile into __sockets__/0 as a
  # single literal. Built by hand here rather than by depending on Phoenix,
  # because the shape is the contract.
  defp endpoint(sockets) do
    %{
      module: My.Endpoint,
      functions: [
        {:function, :__sockets__, 0, 11,
         [
           {:label, 10},
           {:func_info, {:atom, My.Endpoint}, {:atom, :__sockets__}, 0},
           {:label, 11},
           {:move, {:literal, sockets}, {:x, 0}},
           :return
         ]}
      ],
      exports: [],
      attributes: [],
      compile_info: []
    }
  end

  test "records the transports an endpoint switches on" do
    facts =
      endpoint([
        {"/live", Phoenix.LiveView.Socket, [websocket: [], longpoll: [connect_info: []]]}
      ])
      |> Endpoint.extract()

    assert Enum.sort(facts[:socket_transport]) == [
             ["My.Endpoint", "/live", "longpoll"],
             ["My.Endpoint", "/live", "websocket"]
           ]
  end

  test "an explicit false is not enabled, and neither is an absent key" do
    # Phoenix reads a missing key and `false` the same way. Getting this
    # backwards would suppress a real finding on every project that spells
    # the default out, which is the expensive direction to be wrong in.
    facts =
      endpoint([{"/live", Phoenix.LiveView.Socket, [websocket: [], longpoll: false]}])
      |> Endpoint.extract()

    assert facts[:socket_transport] == [["My.Endpoint", "/live", "websocket"]]
  end

  test "a module with no __sockets__/0 contributes nothing" do
    assert Endpoint.extract(%{
             module: Plain,
             functions: [],
             exports: [],
             attributes: [],
             compile_info: []
           }) ==
             %{}
  end
end
