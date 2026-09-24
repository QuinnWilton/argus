# Stub behaviours for the request-surface, transaction, LiveView and
# call-cycle fixtures. None of Phoenix, Plug, Oban, Broadway or Ecto is a dependency of argus;
# the fixtures declare `@behaviour` on them because the analyses read the
# attribute out of the beam. A stub gives the attribute a behaviour to
# name, and every callback is optional so a fixture implements only the
# callbacks its shape needs — defining the rest would add entry points
# the analyses would see.

defmodule Phoenix.LiveView do
  @moduledoc false
  @callback mount(term(), term(), term()) :: term()
  @callback handle_params(term(), term(), term()) :: term()
  @callback handle_event(term(), term(), term()) :: term()
  @callback handle_info(term(), term()) :: term()
  @callback render(term()) :: term()
  @optional_callbacks mount: 3, handle_params: 3, handle_event: 3, handle_info: 2, render: 1
end

defmodule Phoenix.Channel do
  @moduledoc false
  @callback join(term(), term(), term()) :: term()
  @callback handle_in(term(), term(), term()) :: term()
  @callback handle_info(term(), term()) :: term()
  @optional_callbacks join: 3, handle_in: 3, handle_info: 2
end

defmodule Plug do
  @moduledoc false
  @callback init(term()) :: term()
  @callback call(term(), term()) :: term()
  @optional_callbacks init: 1, call: 2
end

defmodule Oban.Worker do
  @moduledoc false
  @callback perform(term()) :: term()
  @optional_callbacks perform: 1
end

defmodule Ecto.Repo do
  @moduledoc false
  @callback transaction(term()) :: term()
  @callback transaction(term(), term()) :: term()
  @callback insert(term()) :: term()
  @optional_callbacks transaction: 1, transaction: 2, insert: 1
end

defmodule Broadway do
  @moduledoc false
  @callback handle_message(term(), term(), term()) :: term()
  @callback handle_batch(term(), term(), term(), term()) :: term()
  @optional_callbacks handle_message: 3, handle_batch: 4
end
