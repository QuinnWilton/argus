defmodule Argus.Test.Fixtures.ApiSurface do
  @moduledoc """
  A library's documented API beside the helpers its docs hide (unsafe_input's
  `outside_api`): a hidden export the library calls itself takes what the
  library hands it, a documented export takes what its user hands it.
  """

  alias Argus.Test.Fixtures.ApiSurface.Grammar

  @doc "Turns the caller's name into an atom: the caller chooses the atom."
  def documented(name), do: String.to_atom(name)

  @doc "Hands the caller's word to a hidden helper, which makes it an atom."
  def forwards(word), do: Grammar.word(word)

  @doc "Parses a statement against no schema."
  def parse(tokens), do: describe(tokens)

  # SQL.Parser.describe/2's shape: a hidden function the library calls with
  # an empty schema, whose columns become atoms.
  @doc false
  def describe(tokens, columns \\ []), do: {tokens, columns(columns)}

  defp columns([]), do: []
  defp columns(columns), do: Enum.map(columns, &:"#{&1.type}_#{&1.name}")

  @doc "Lists the grammar's keywords."
  def keywords, do: Grammar.rules()
end

defmodule Argus.Test.Fixtures.ApiSurface.Grammar do
  @moduledoc false

  # SQL.BNF's shape: a hidden module turning a fixed grammar into atoms,
  # called only by the library's own code with literals.
  def rules(source \\ "select from where"), do: source |> String.split() |> keywords()

  def keywords(words), do: for(word <- words, do: keyword(word))

  def keyword(word), do: String.to_atom(String.downcase(word))

  # A documented function hands this the caller's word.
  def word(word), do: String.to_atom(word)

  # Nothing in the program calls this: whoever does is outside it.
  def orphan(name), do: String.to_atom(name)

  # A request handler hands this the request's parameter.
  def param(name), do: String.to_atom(name)
end

defmodule Argus.Test.Fixtures.ApiSurface.Plug do
  @moduledoc false
  @behaviour Plug

  alias Argus.Test.Fixtures.ApiSurface.Grammar

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: {conn, Grammar.param(conn.params["name"])}
end
