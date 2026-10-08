# Helpers only Mix tasks call (clientlib/tooling.dl's tooling_helper):
# each module runs a shell command handed in by its caller, which
# unsafe_input reports as code execution the exports reach (`:error`),
# and steps down to `:warning` in tooling. Shaped like ex_quality, whose
# `ExQuality.Stages.*` only `Mix.Tasks.Quality` runs.

defmodule Mix.ArgusFixtures.ContractTooling do
  @moduledoc false

  alias Argus.Test.Fixtures.{ContractToolingApi, ContractToolingHelper, ContractToolingShared}

  # The Mix task: tooling by its name. A capture handed to a call is a
  # call, as `stage(..., &Credo.run/1)` is in ex_quality.
  def run(command) do
    ContractToolingHelper.run(command)
    ContractToolingShared.run(command)
    ContractToolingApi.run(command)
    Enum.map([command], &ContractToolingHelper.check/1)
  end
end

defmodule Argus.Test.Fixtures.ContractToolingHelper do
  @moduledoc false

  alias Argus.Test.Fixtures.ContractToolingDeep

  # Every export is called in the program, only by the Mix task: a helper
  # Mix tasks share, tooling.
  def run(command) do
    ContractToolingDeep.run(command)
    :os.cmd(String.to_charlist(command))
  end

  def check(command), do: :os.cmd(String.to_charlist(command <> " --check"))
end

defmodule Argus.Test.Fixtures.ContractToolingDeep do
  @moduledoc false

  # Called only by a helper only the Mix task calls: tooling too (the
  # fixpoint).
  def run(command), do: :os.cmd(String.to_charlist(command))
end

defmodule Argus.Test.Fixtures.ContractToolingShared do
  @moduledoc false

  # The Mix task calls it, and so does the product: not tooling.
  def run(command), do: :os.cmd(String.to_charlist(command))
end

defmodule Argus.Test.Fixtures.ContractToolingProduct do
  @moduledoc false

  alias Argus.Test.Fixtures.ContractToolingShared

  def handle(command), do: ContractToolingShared.run(command)
end

defmodule Argus.Test.Fixtures.ContractToolingApi do
  @moduledoc false

  # The Mix task calls `run/1`, but `version/0` nothing in the program
  # calls: the module is a way in for the library's own users, whose
  # callers argus does not see, and stays product.
  def run(command), do: :os.cmd(String.to_charlist(command))

  def version, do: "1.0.0"
end
