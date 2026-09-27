defmodule Argus.Schema.Web do
  @moduledoc """
  What a web application declares: its routes, the fields of its Ecto
  schemas with the ones it redacts, which fields a derived `Inspect`
  prints, and where a LiveView asks whether it is connected.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        name: :connected_guarded,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: """
        The call at `id` runs only on the arm where \
        `Phoenix.LiveView.connected?/1` answered true (or \
        `get_connect_params/1` answered, not nil, as it does only once \
        connected): the block that arm's edge alone enters dominates the \
        call's (Argus.Extractors.LiveView). A LiveView's mount runs once \
        for the static render, in the HTTP connection's process, and again \
        connected; what registers the process for later messages belongs \
        on that arm. A call on the other arm, or after the arms join, has \
        no row.
        """
      },
      %{
        name: :pubsub_call,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "containing function ID"},
          {:op, :symbol, "subscribe | unsubscribe"},
          {:via, :symbol,
           "pubsub (Phoenix.PubSub, :pg), the module whose subscribe/1,2 or " <>
             "unsubscribe/1 it is, or apply (a module held in a value)"}
        ],
        doc: """
        The call at `id` subscribes the calling process to a topic or joins \
        it to a group, or undoes that (Argus.Extractors.LiveView): \
        `Phoenix.PubSub.subscribe/2,3` and `unsubscribe/2`, `:pg.join` and \
        `:pg.leave` (`pubsub`); a module's own `subscribe/1,2` or \
        `unsubscribe/1`, which is an endpoint's when the module is one \
        (`via` names it); or `socket.endpoint.subscribe(topic)`, an apply of \
        either name to a module held in a value (`apply`).
        """
      },
      %{
        name: :schema_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a persisted field"},
          {:type, :symbol,
           "its Ecto type as a reader is told it: 'string', a custom type's module, " <>
             "'embeds_one Mod', 'array of string'; 'dynamic' when __schema__/2 does not say"}
        ],
        doc: """
        A field on an Ecto schema, read from the literal in `__schema__/1`, \
        with its type from `__schema__(:type, field)`. No rule reads the type; \
        `Argus.Priors.Questions.Sensitivity` shows it to the model beside the \
        name, where `Sequin.Encrypted.Field` or `embeds_one \
        Sequin.Sinks.Gcp.Credentials` says what the name alone does not.
        """
      },
      %{
        name: :lineless_schema,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"}
        ],
        doc: """
        An Ecto schema whose `__schema__/1` carries no line: every line \
        marker is line 0. An `embeds_one :totp, TOTP do ... end` block \
        compiles its module with none (akkoma's `Pleroma.MFA.Settings.TOTP`), \
        so a finding about its fields is anchored at the schema that embeds it.
        """
      },
      %{
        name: :redacted_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a field declared redact: true"}
        ],
        doc: """
        A field declared `redact: true`, which Ecto excludes from `inspect/1` \
        unless the schema derives `Inspect` itself (`inspect_derived`). \
        Absence is the interesting case — `redact` defaults to off — so \
        consumers ask by negation.
        """
      },
      %{
        name: :inspect_derived,
        layer: 2,
        fields: [
          {:mod, :symbol, "the struct module"}
        ],
        doc: """
        The struct's `Inspect` is derived — `@derive Inspect` with or without \
        `except:`/`only:`, or Ecto's own derive for its `redact: true` fields — \
        read from the `Inspect.<Struct>` implementation module. When there is \
        one, it alone decides which fields `inspect/1` prints \
        (`inspect_shows`). A hand-written implementation has no row.
        """
      },
      %{
        name: :inspect_shows,
        layer: 2,
        fields: [
          {:mod, :symbol, "the struct module"},
          {:field, :symbol, "a field its derived Inspect prints"}
        ],
        doc: """
        A field a derived `Inspect` prints: the fields its guard admits, \
        after `except:` and `only:`. A field of an `inspect_derived` struct \
        with no row here is hidden from `inspect/1`.
        """
      }
    ])
  end
end
