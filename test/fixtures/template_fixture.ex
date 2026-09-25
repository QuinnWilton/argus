defmodule Argus.Test.Fixtures.Template do
  @moduledoc """
  A Phoenix view as Phoenix.Template compiles it, for the `rendered`
  proximity of `unsafe_input`: each template is a function of its assigns
  named `name.format`, and render/2 dispatches on the name.
  """

  defmodule ScopesView do
    @moduledoc """
    akkoma's OAuthView: Phoenix.Template compiles `_scopes.html.eex` to a
    function of its assigns named `"_scopes.html"`, dispatched from the
    view's render/2. The template makes a form field atom of each scope
    the controller hands it. `labels.html` makes one of a literal.
    """
    def render(template, assigns), do: render_template(template, assigns)

    def render_template("_scopes.html", assigns), do: __MODULE__."_scopes.html"(assigns)
    def render_template("labels.html", assigns), do: __MODULE__."labels.html"(assigns)

    def unquote(:"_scopes.html")(assigns) do
      for scope <- assigns.available_scopes, do: String.to_atom("scope_" <> scope)
    end

    def unquote(:"labels.html")(_assigns), do: String.to_atom("scope_read")
  end

  defmodule OAuthController do
    @moduledoc """
    The authorize action renders the scopes of the app its `client_id`
    names, which anyone registered with scopes of their choosing: the
    atoms come from a row, not the params, and from the template's
    assigns.
    """
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)

    def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

    def action(%{private: %{phoenix_action: name}} = conn, _opts),
      do: apply(__MODULE__, name, [conn, conn.params])

    def authorize(conn, params) do
      app = Argus.Test.Fixtures.Taint.Store.load(params["client_id"])
      {conn, ScopesView.render("_scopes.html", %{available_scopes: app.scopes})}
    end

    def labels(conn, _params), do: {conn, ScopesView.render("labels.html", %{})}
  end
end
