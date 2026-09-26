defmodule B.MixProject do
  use Mix.Project

  def project do
    [
      app: :b,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: []
    ]
  end
end
