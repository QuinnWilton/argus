defmodule Argus.Test.Fixtures.BuildCallback do
  @moduledoc """
  Atom sinks in callbacks the build runs: a template engine's, handed a
  template's source at compile time, and a Mix SCM's, handed a
  dependency's metadata. Whoever writes either already runs code in the
  build, so neither is an outside party's way in; a runtime helper of the
  same engine still is.
  """

  defmodule Engine do
    @moduledoc "A template engine making an atom of each tag it compiles."
    @behaviour EEx.Engine

    @impl true
    def init(_opts), do: []
    @impl true
    def handle_body(state), do: state
    @impl true
    def handle_begin(state), do: state
    @impl true
    def handle_end(state), do: state
    @impl true
    def handle_text(state, _meta, text), do: [String.to_atom(text) | state]
    @impl true
    def handle_expr(state, _marker, expr), do: [Code.eval_quoted(expr) | state]

    # Called by the compiled template at runtime, with what the page hands it.
    def render_attr(name), do: String.to_atom(name)
  end

  defmodule SCM do
    @moduledoc "A Mix SCM making atoms of the managers a dependency's metadata names."
    @behaviour Mix.SCM

    @impl true
    def fetchable?, do: true
    @impl true
    def format(_opts), do: "scm"
    @impl true
    def format_lock(_opts), do: nil
    @impl true
    def accepts_options(_app, opts), do: opts
    @impl true
    def checked_out?(_opts), do: true
    @impl true
    def lock_status(_opts), do: :ok
    @impl true
    def equal?(_a, _b), do: true
    @impl true
    def managers(opts), do: Enum.map(Keyword.get(opts, :managers, []), &String.to_atom/1)
    @impl true
    def checkout(opts), do: opts
    @impl true
    def update(opts), do: opts
  end

  defmodule HiddenSCM do
    @moduledoc false
    # Hex.SCM's shape: a hidden module whose helper, which its callback calls,
    # makes atoms of a manifest line. The helper is no callback, and the
    # program calls it: no way in either.
    @behaviour Mix.SCM

    @impl true
    def fetchable?, do: true
    @impl true
    def format(_opts), do: "hidden"
    @impl true
    def format_lock(_opts), do: nil
    @impl true
    def accepts_options(_app, opts), do: opts
    @impl true
    def checked_out?(_opts), do: true
    @impl true
    def lock_status(_opts), do: :ok
    @impl true
    def equal?(_a, _b), do: true
    @impl true
    def managers(opts), do: parse_managers(Keyword.get(opts, :line, ""))
    @impl true
    def checkout(opts), do: opts
    @impl true
    def update(opts), do: opts

    def parse_managers(line), do: line |> String.split(",") |> Enum.map(&String.to_atom/1)
  end

end
