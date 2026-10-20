defmodule Argus.Test.Fixtures.Validator do
  @moduledoc """
  Atom sinks behind a validator: a function that returns only when its
  argument is one of a set the program wrote, and raises on any other. The
  argument is bounded past a call to it, however the validator is reached.
  """

  defmodule Roles do
    @moduledoc "Roles are one of three; anything else raises."
    @roles ~w(admin editor viewer)

    # A raising helper validates its argument before the sink.
    def helper(role) do
      validate!(role)
      String.to_atom(role)
    end

    # A helper that validates through another validator.
    def wrapped(role) do
      check!(role)
      String.to_atom(role)
    end

    # Each element is validated before the list is mapped through the sink.
    def each(roles) do
      Enum.each(roles, &validate!/1)
      Enum.map(roles, &String.to_atom/1)
    end

    # A check that answers instead of raising validates nothing: the sink
    # runs on the :error path too.
    def answers(role) do
      _ = known?(role)
      String.to_atom(role)
    end

    # The validator checks another argument than the one the sink takes.
    def other(role, name) do
      validate!(role)
      String.to_atom(name)
    end

    def unchecked(role), do: String.to_atom(role)

    defp check!(role), do: validate!(role)

    defp validate!(role) do
      unless role in @roles, do: raise(ArgumentError, "unknown role #{inspect(role)}")
      :ok
    end

    defp known?(role), do: if(role in @roles, do: :ok, else: :error)
  end
end
