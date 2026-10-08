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

  # The program calls this with a literal, and so does a function
  # `ApiSurface.Router.events/0` generates, with its caller's event.
  def event(name), do: String.to_atom(name)
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

defmodule Argus.Test.Fixtures.ApiSurface.Router do
  @moduledoc """
  Macros whose quotes call this module (phoenix_replay's router): where a
  quoted call runs decides whose data its parameters take.
  """

  alias Argus.Test.Fixtures.ApiSurface.Grammar

  @doc "Defines the routes under `path`, in a router's body."
  defmacro mount(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      {session, frame} = Argus.Test.Fixtures.ApiSurface.Router.__sessions__(path, opts)

      scope path do
        live_session(session, frame)
      end
    end
  end

  @doc "Builds `mount/2`'s session names as the router compiles."
  def __sessions__(path, opts) do
    name = Keyword.get(opts, :as, :mount)
    {name, :"#{name}_frame_#{path}"}
  end

  @doc "Defines `handle/1`, which hands its caller's name to `__handle__/1`."
  defmacro handler do
    quote do
      def handle(name), do: Argus.Test.Fixtures.ApiSurface.Router.__handle__(name)
    end
  end

  @doc "Runs in a generated `handle/1`, on what its caller hands it."
  def __handle__(name), do: String.to_atom(name)

  @doc "Names an atom where it expands."
  defmacro named(name) do
    quote bind_quoted: [name: name] do
      Argus.Test.Fixtures.ApiSurface.Router.name_atom(name)
    end
  end

  @doc "Turns a name into an atom: documented, so anyone may call it."
  def name_atom(name), do: String.to_atom(name)

  @doc "Registers a name where it expands."
  defmacro register(name) do
    quote bind_quoted: [name: name] do
      Argus.Test.Fixtures.ApiSurface.Router.__register__(name)
    end
  end

  @doc "Registers `register/1`'s name; the program's runtime calls it too."
  def __register__(name), do: String.to_atom(name)

  @doc "Registers the default name at runtime."
  def register_default, do: __register__("default")

  @doc "Defines `handle_event/3`, which hands the event's name to a hidden helper."
  defmacro events do
    quote do
      def handle_event(name, _params, socket),
        do: {Argus.Test.Fixtures.ApiSurface.Grammar.event(name), socket}
    end
  end

  @doc "The event the program opens with."
  def opening, do: Grammar.event("open")
end

defmodule Argus.Test.Fixtures.ApiSurface.QuoteShapes do
  @moduledoc "Quotes whose calls name no module, or no arity (`Argus.Extractors.Quoted`)."

  @doc "Calls the expansion site's own module."
  defmacro own(x), do: quote(do: __MODULE__.helper(unquote(x)))

  @doc "Calls a hook on an unquoted argument where it expands."
  defmacro unquoted(x),
    do: quote(do: Argus.Test.Fixtures.ApiSurface.QuoteShapes.__hook__(unquote(x)))

  @doc "Calls a hook on an unquoted argument inside a fun."
  defmacro in_fn(x),
    do: quote(do: fn -> Argus.Test.Fixtures.ApiSurface.QuoteShapes.__hook__(unquote(x)) end)

  @doc "The hook."
  def __hook__(x), do: x
end
