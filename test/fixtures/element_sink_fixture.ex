defmodule Argus.Test.Fixtures.ElementSink do
  @moduledoc """
  Sinks a higher-order call runs on each element of its collection, handed
  as a capture: each call of the sink takes an element, and the element is
  the caller's data.
  """

  defmodule Permissions do
    @moduledoc "Guardian's permission decoding: names from a token become atoms."
    def decode(names) when is_list(names), do: Enum.map(names, &String.to_atom/1)
  end

  defmodule Terms do
    @moduledoc "The Erlang shape: the fun first, the list second."
    def decode_all(blobs), do: :lists.map(&:erlang.binary_to_term/1, blobs)
  end

  defmodule Joined do
    @moduledoc "A capture beside a joiner: the fun is the third argument."
    def keys(names), do: Enum.map_join(names, ",", &String.to_atom/1)
  end

  defmodule Literal do
    @moduledoc "A collection the program wrote: its elements are those literals."
    def roles, do: Enum.map(~w(admin editor viewer), &String.to_atom/1)
  end

  defmodule NotASink do
    @moduledoc "A capture of a function that is no sink."
    def shout(names), do: Enum.map(names, &String.upcase/1)
  end
end
