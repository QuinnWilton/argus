defmodule Argus.Test.Fixtures.RawSqlModule do
  @moduledoc false

  # Simulate a raw SQL call. Ecto.Adapters.SQL may not be available in test,
  # but the call instruction is still emitted.
  def raw_query(repo, sql) do
    Ecto.Adapters.SQL.query(repo, sql)
  end
end

defmodule Argus.Test.Fixtures.SafeSqlModule do
  @moduledoc false

  # Uses parameterized query — not flagged as raw SQL directly.
  def safe_query(repo, sql, params) do
    Ecto.Adapters.SQL.query(repo, sql, params)
  end
end

defmodule Argus.Test.Fixtures.RedirectModule do
  @moduledoc false

  # Simulates Phoenix.Controller.redirect/2 calls.
  def static_redirect(conn) do
    Phoenix.Controller.redirect(conn, to: "/dashboard")
  end

  def dynamic_redirect(conn, url) do
    Phoenix.Controller.redirect(conn, external: url)
  end

  def static_external_redirect(conn) do
    Phoenix.Controller.redirect(conn, external: "https://example.com")
  end
end

defmodule Argus.Test.Fixtures.NonControllerWithActions do
  @moduledoc false

  # Module with delete/2 and update/2 but no Phoenix markers.
  # Should NOT emit controller_action facts.
  def delete(repo, id), do: {repo, id}
  def update(repo, data), do: {repo, data}
  def index(conn, params), do: {conn, params}
end
