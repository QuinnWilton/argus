defmodule Argus.Analyses.PhoenixSecurity do
  @moduledoc """
  Phoenix/Plug security analysis.

  Detects web application security issues: raw SQL queries reachable from
  controller actions, open redirects, and missing security plugs.

  ## Output relations

  - `sql_injection_risk(func, api)` — raw SQL reachable from controller action.
  - `open_redirect_risk(func)` — redirect with dynamic target.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :phoenix_security

  @impl true
  def description, do: "Phoenix security: SQL injection, open redirect, missing plugs"

  @impl true
  def rules_file, do: "analyses/phoenix_security.dl"

  @impl true
  def extractors, do: [Argus.Extractors.PhoenixSecurity]

  @impl true
  def output_relations do
    [
      %{
        name: :sql_injection_risk,
        fields: [
          {:func, :symbol, "function with raw SQL"},
          {:api, :symbol, "SQL API"}
        ],
        doc: "Raw SQL reachable from controller action."
      },
      %{
        name: :open_redirect_risk,
        fields: [{:func, :symbol, "function with dynamic redirect"}],
        doc: "Redirect with dynamic target (open redirect risk)."
      }
    ]
  end
end
