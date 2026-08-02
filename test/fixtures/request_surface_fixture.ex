defmodule Argus.Test.Fixtures.RequestSurface do
  @moduledoc """
  Fixtures for the request-surface analysis.

  The behaviours are declared with a bare `@behaviour` attribute naming a
  module that does not exist here — that is deliberate and sufficient.
  `Argus.Extractors.OTP` reads the `behaviour` attribute out of the beam,
  so the analysis sees `implements_behaviour(mod, "Plug")` without this
  test suite having to depend on Phoenix, Plug, Oban or Broadway.
  """

  defmodule DirectPlug do
    @moduledoc "Sink inside the callback: the argument IS the request."
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      # Straight from the request, no validation. This is the shape that
      # was a true positive in livebook.
      String.to_atom(conn.params["tag"])
    end
  end

  defmodule AdjacentLiveView do
    @moduledoc "Sink one call away — the shape supabase/realtime had."
    @behaviour Phoenix.LiveView

    def handle_params(params, _url, socket) do
      order_by(params["order_by"])
      {:noreply, socket}
    end

    def order_by(field), do: String.to_atom(field)
  end

  defmodule TransitiveWorker do
    @moduledoc "Sink several calls away, through a helper."
    @behaviour Oban.Worker

    def perform(job), do: level_one(job)
    def level_one(job), do: level_two(job)
    def level_two(job), do: String.to_atom(job.args["kind"])
  end

  defmodule SafeCallback do
    @moduledoc "A callback that converts safely — must never be flagged."
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      String.to_existing_atom(conn.params["tag"])
    end
  end

  defmodule NotAnEntryPoint do
    @moduledoc """
    Same unsafe call, but the module implements no request-handling
    behaviour. Guards against the analysis degenerating into "any exported
    function", which is exactly what it exists to improve on.
    """
    def load_config(name), do: String.to_atom(name)
  end
end
