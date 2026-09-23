defmodule Argus.Schema.Web do
  @moduledoc """
  What a web application declares: its routes, and the fields of its
  Ecto schemas with the ones it redacts.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
      %{
        name: :http_route,
        layer: 2,
        fields: [
          {:router, :symbol, "the router module"},
          {:verb, :symbol, "the HTTP method"},
          {:path, :symbol, "the route path, with its placeholders"},
          {:plug, :symbol, "the controller or LiveView"},
          {:action, :symbol, "the action or live action"}
        ],
        doc: """
        A route from `Phoenix.Router.__routes__/0`. `pipe_through` is absent \
        because Phoenix compiles pipelines into the dispatch function rather \
        than into this literal, so whether a route is authenticated is \
        derivable but not from here.
        """
      },
      %{
        name: :schema_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a persisted field"}
        ],
        doc: "A field on an Ecto schema, read from the literal in __schema__/1."
      },
      %{
        name: :redacted_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a field declared redact: true"}
        ],
        doc: """
        A field Ecto excludes from `inspect/1`. Absence is the interesting \
        case — `redact` defaults to off — so consumers ask by negation.
        """
      }
    ]
  end
end
