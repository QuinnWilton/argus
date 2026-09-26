defmodule A.MixProject do
  use Mix.Project

  def project do
    [
      app: :a,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      compilers: Mix.compilers() ++ [:argus],
      scry: [analyses: [:mailbox]],
      deps: [{:b, in_umbrella: true}]
    ]
  end
end
