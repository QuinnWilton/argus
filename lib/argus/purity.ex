defmodule Argus.Purity do
  @moduledoc """
  Declare that a function performs no side effects, and have it checked.

  Every other argus analysis looks for bugs nobody claimed were absent.
  This one verifies a claim the author made, which changes what a finding
  means: not "this looks suspicious" but "you said this was pure and here is
  the call that makes it not".

      defmodule Money do
        use Argus.Purity

        @pure true
        def add(%Money{cents: a}, %Money{cents: b}), do: %Money{cents: a + b}
      end

  Then `mix argus purity` reports any declared-pure function that reaches a
  side effect, naming the effect and the path to it.

  ## How the declaration survives compilation

  `@pure` is a marker read by an `@on_definition` hook, which accumulates
  `{name, arity}` into a **persisted** module attribute. Persisted
  attributes are written into the beam's attribute chunk, so
  `Argus.Extractors` sees them as `module_attribute` facts and the analysis
  reads the contract out of the artifact. Nothing has to parse source, and
  the declaration cannot drift from the code it describes — they are
  compiled together.

  This is also why the marker is `@pure true` before the `def` rather than,
  say, `defpure`: no macro wraps the function, so the emitted code is
  byte-for-byte what it would have been without the declaration. Purity here
  costs nothing at runtime and changes nothing about the beam except three
  extra bytes of attribute.

  ## What "pure" means here

  Free of *observable effects*: no message send or receive, no process
  spawn, no ETS, no ports, no process registration, no process dictionary,
  no I/O, no clock or randomness, and no call to anything that does those
  things. Allocation, arithmetic, pattern matching, and calls to other pure
  functions are all fine.

  Exceptions are deliberately allowed. A function that raises is still pure
  in the sense that matters here — it computes a value or fails, and it
  leaves nothing behind.

  ## Honesty about what cannot be proven

  A call through a fun value or `apply/3` cannot be followed, so a function
  containing one is reported as **unprovable** rather than pure or impure.
  That is the point of the analysis: a claim of purity is a claim about all
  executions, and quietly ignoring the calls it cannot see would make the
  answer worthless. This is the only argus analysis that has to be sound
  rather than merely useful, because a wrong "verified" is worse than no
  verification at all.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :pure, persist: false)

      # Persisted, so it lands in the beam's attribute chunk and becomes a
      # module_attribute fact.
      Module.register_attribute(__MODULE__, :argus_pure, accumulate: true, persist: true)

      @on_definition Argus.Purity
    end
  end

  @doc false
  # Runs after each definition. Reads the marker, records the function, and
  # clears it — otherwise one `@pure` would silently apply to every
  # definition after it, which is the classic module-attribute footgun and
  # would make the contract mean nothing.
  def __on_definition__(env, kind, name, args, _guards, _body)
      when kind in [:def, :defp] do
    if Module.get_attribute(env.module, :pure) do
      Module.put_attribute(env.module, :argus_pure, {name, length(args)})
      Module.delete_attribute(env.module, :pure)
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc """
  The `{name, arity}` pairs a compiled module declared pure.

  Reads the beam attribute rather than the source, so it answers for the
  artifact actually running.
  """
  @spec declared(module()) :: [{atom(), arity()}]
  def declared(module) when is_atom(module) do
    :attributes
    |> module.module_info()
    |> Keyword.get_values(:argus_pure)
    |> List.flatten()
  rescue
    UndefinedFunctionError -> []
  end
end
