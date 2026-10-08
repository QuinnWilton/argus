defmodule Argus.Test.FixtureSpread do
  @moduledoc """
  The fixtures a check reruns extraction over, picked by a fixed rule
  rather than a kept list, so adding or renaming a fixture needs nothing
  here.

    * `all/0`: every `Argus.Test.Fixtures.` module, and runtime modules
      with shapes no fixture compiles. For a check that runs extraction
      once or twice over everything.
    * `spread/0`: one fixture in twenty, by a portable hash of its name
      (adding a fixture does not move the others in or out), the
      fixtures a few extractors need, named so that the hash cannot move
      them out, and the same runtime modules. For a check that reruns
      extraction per producer. Every producer writes rows for some of
      them (`Argus.Graph.Identity.ProducersTest` checks).
  """

  # Shapes no fixture compiles: OTP's behaviours, a derived Inspect
  # implementation, and Elixir modules with a formatter's and a parser's
  # control flow.
  @runtime [
    Inspect.Argus.Test.Fixtures.DerivedInspect.OneField,
    Logger.Formatter,
    URI,
    :gen_server,
    :supervisor
  ]

  # The only fixtures some extractor writes rows for, or the only ones
  # with a shape it reads.
  @named [
    Argus.Test.Fixtures.SimpleStatem,
    Argus.Test.Fixtures.Specs,
    Argus.Test.Fixtures.Router,
    Argus.Test.Fixtures.LiveEndpoint,
    Argus.Test.Fixtures.ParamFlow.Returns,
    Argus.Test.Fixtures.SecurityValues,
    Argus.Test.Fixtures.ResultChecks,
    Argus.Test.Fixtures.CodeInjection,
    Argus.Test.Fixtures.SqlInjection,
    Argus.Test.Fixtures.SqlComments,
    Argus.Test.Fixtures.PathTraversal,
    Argus.Test.Fixtures.HtmlInjection,
    Argus.Test.Fixtures.EtfAllocation,
    :term_validation_fixture,
    Argus.Test.Fixtures.SharedStoreClaim.Helpers,
    Argus.Test.Fixtures.SharedStoreClaim.Atomic,
    Argus.Test.Fixtures.Secret.Typed,
    Argus.Test.Fixtures.Tls.ForcesNone,
    Argus.Test.Fixtures.DerivedInspect.OneField,
    Argus.Test.Fixtures.ApiSurface.QuoteShapes,
    Mix.ArgusFixtures.Seed
  ]

  @doc "Every fixture, and the runtime modules."
  @spec all() :: [module()]
  def all, do: fixtures() ++ @runtime

  @doc "A spread of the fixtures, the named ones, and the runtime modules."
  @spec spread() :: [module()]
  def spread do
    hashed = Enum.filter(fixtures(), &(:erlang.phash2(&1, 20) == 0))
    Enum.uniq(hashed ++ @named ++ @runtime)
  end

  @doc "The beam files of `modules`."
  @spec beams([module()]) :: [String.t()]
  def beams(modules), do: Enum.map(modules, &to_string(:code.which(&1)))

  defp fixtures do
    Enum.sort(
      for mod <- Application.spec(:argus_beam, :modules),
          String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Test.Fixtures."),
          do: mod
    )
  end
end
