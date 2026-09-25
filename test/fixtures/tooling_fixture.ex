# Code only developers' tools or tests run (clientlib/tooling.dl,
# Argus.Findings.Tooling): three modules making the same call, a shell
# command handed in by the caller, which unsafe_input reports as code
# execution the exports reach (`:error`).

defmodule Mix.ArgusFixtures.Seed do
  @moduledoc false

  # Under `Mix.`: a helper Mix tasks share, tooling by its name alone. Its
  # finding steps down to `:warning`, structurally. (Not a `Mix.Tasks.`
  # module, so `mix help` does not list it.)
  def run(command), do: :os.cmd(String.to_charlist(command))
end

defmodule Argus.Test.Fixtures.Tooling.Product do
  @moduledoc false

  # The same call in the product: the finding at its structural severity.
  def run(command), do: :os.cmd(String.to_charlist(command))
end

defmodule Argus.Test.Fixtures.Tooling.DevSetup do
  @moduledoc false

  # A development-only setup no structure names: its finding stays
  # `:error`.
  def run(command), do: :os.cmd(String.to_charlist(command))
end
