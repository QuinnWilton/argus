defmodule Depot.MixProject do
  # A small project with known findings for test/deploy/check.sh: argus
  # comes from the checkout (ARGUS_SRC, a path) or from Hex (ARGUS_VERSION).
  use Mix.Project

  def project do
    [
      app: :depot,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: Mix.compilers() ++ if(Mix.env() in [:dev, :test], do: [:argus], else: []),
      argus: [analyses: [:coupling, :mailbox]],
      deps: [argus()]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp argus do
    case {System.get_env("ARGUS_SRC"), System.get_env("ARGUS_VERSION")} do
      {src, _} when src not in [nil, ""] ->
        {:argus_beam, path: src, only: [:dev, :test], runtime: false}

      {_, version} when version not in [nil, ""] ->
        {:argus_beam, "== #{version}", only: [:dev, :test], runtime: false}
    end
  end
end
