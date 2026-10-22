defmodule Argus.Test.Stages do
  @moduledoc """
  The shared stages over a facts directory a test built: stage 0, the
  points-to stage and the values stage, derived as a solve over the
  directory would find them, so that a program including
  `clientlib/imports.dl` reads every staged relation it declares.
  """

  alias Argus.Analysis

  @doc "Derives stage 0, then the stages over it, into `facts_dir`."
  @spec derive!(Path.t()) :: Path.t()
  def derive!(facts_dir) do
    :ok = Analysis.derive_stage0(facts_dir)
    derive_over_stage0!(facts_dir)
  end

  @doc """
  Derives the points-to and values stages into `facts_dir`, over the
  stage 0 relations the test wrote there itself.
  """
  @spec derive_over_stage0!(Path.t()) :: Path.t()
  def derive_over_stage0!(facts_dir) do
    :ok = Analysis.derive_points_to(facts_dir)
    :ok = Analysis.derive_values(facts_dir)
    facts_dir
  end
end
