defmodule Argus.Extractor.Runtime do
  @moduledoc """
  The modules of the runtime every program runs on: ERTS, Kernel, STDLIB,
  Elixir and Logger.

  Extractors that summarise what a function does with a value follow it
  into project code only: a call into `Enum` or `:gen_server` has no
  summary to join, and recording it anyway doubles the rows. Two of them
  used to decide "is this the runtime" differently — one by a compile-time
  set of these applications, the other by asking the code server where the
  module was loaded from, once per call site (about 120µs a miss, and
  every site misses when the analyzed program is not loaded in the VM).
  This is the one answer both use.

  The set is fixed when argus is compiled. Other OTP applications (ssl,
  mnesia, inets, ...) are left out on purpose: analyzing one of them as
  the program is a supported use, and their calls then have summaries to
  follow.
  """

  use Argus.Purity

  @runtime_modules for(
                     app <- [:erts, :kernel, :stdlib, :elixir, :logger],
                     _ = Application.load(app),
                     mod <- Application.spec(app, :modules) || [],
                     into: MapSet.new(),
                     do: mod
                   )
                   |> MapSet.union(MapSet.new(:erlang.pre_loaded()))

  @doc """
  Whether `mod` belongs to the runtime rather than to the program.

      iex> Argus.Extractor.Runtime.module?(:gen_server)
      true

      iex> Argus.Extractor.Runtime.module?(GenServer)
      true

      iex> Argus.Extractor.Runtime.module?(Argus.Extractor.Runtime)
      false
  """
  @spec module?(module()) :: boolean()
  @pure true
  def module?(mod) when is_atom(mod), do: MapSet.member?(@runtime_modules, mod)
end
