defmodule Argus.Test.Fixtures.DerivedInspect do
  @moduledoc """
  The shapes a derived Inspect compiles to, beyond `except:` and `only:`
  (those are in `Argus.Test.Fixtures.Secret`).
  """

  defmodule ShowsNothing do
    @moduledoc "`only: []`: the filter compiles away."
    @derive {Inspect, only: []}
    defstruct [:id, :token]
  end

  defmodule OneField do
    @moduledoc "One field kept: an is_eq_exact, not a select_val."
    @derive {Inspect, except: [:token]}
    defstruct [:id, :token]
  end

  defmodule Optional do
    @moduledoc "`optional:` adds a default check after the guard."
    @derive {Inspect, except: [:token], optional: [:name]}
    defstruct [:id, :token, name: "x"]
  end

  defmodule HandWritten do
    @moduledoc "An Inspect written by hand: its output is not a field list."
    defstruct [:id, :token]

    defimpl Inspect do
      def inspect(%{id: id}, _opts), do: "#HandWritten<#{id}>"
    end
  end
end
