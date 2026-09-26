defmodule Argus.Test.Fixtures.RpcTarget do
  @moduledoc false
  # Rpcs to functions of the program's own modules (failure's
  # rpc_undefined): what the module exports decides.

  defmodule Remote do
    @moduledoc false
    def run(a, b), do: {a, b}
    def ping, do: :pong
    defp secret(x), do: x
    def use_secret(x), do: secret(x)
  end

  # realtime's Rpc wrapper: the MFA reaches :erpc.call through a closure
  # :timer.tc runs.
  defmodule Wrapper do
    @moduledoc false
    def enhanced_call(node, mod, func, args \\ [], opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 15_000)
      {_latency, response} = :timer.tc(fn -> :erpc.call(node, mod, func, args, timeout) end)
      response
    end

    def call(node, mod, func, args), do: :rpc.call(node, mod, func, args, 5_000)

    # A wrapper that forwards the three to another is one too.
    def forward(node, mod, func, args), do: call(node, mod, func, args)
  end

  defmodule Caller do
    @moduledoc false
    alias Argus.Test.Fixtures.RpcTarget.{Remote, Wrapper}

    # realtime before d2f5339: a function the module never defined.
    def missing(node), do: Wrapper.enhanced_call(node, Remote, :run_db_request, [1, 2])

    # realtime before ac00218: the arity is one too many.
    def wrong_arity(node), do: :erpc.call(node, Remote, :run, [1, 2, 3])

    def private(node), do: :rpc.call(node, Remote, :secret, [1])

    def forwarded(node), do: Wrapper.forward(node, Remote, :nope, [])

    # The fixes: exported functions at their arities.
    def ok_direct(node), do: :erpc.call(node, Remote, :run, [1, 2])
    def ok_wrapped(node), do: Wrapper.enhanced_call(node, Remote, :ping, [])
    def ok_forwarded(node), do: Wrapper.forward(node, Remote, :use_secret, [3])

    # A module outside the program says nothing about its exports.
    def outside(node), do: :rpc.call(node, :some_library, :anything, [])

    # A list whose length is not known names no function.
    def unknown_length(node, rest), do: :erpc.call(node, Remote, :run, [1 | rest])
  end
end
