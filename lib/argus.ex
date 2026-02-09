defmodule Argus do
  @moduledoc """
  BEAM program analysis via Souffle Datalog.

  Argus extracts facts from BEAM bytecode and feeds them to Souffle Datalog
  rules for whole-program, multi-module analysis. The pipeline is:

      .beam files → normalize → emit facts → Souffle rules → results

  ## Quick start

      # Analyze a single module's control flow graph.
      Argus.analyze([:lists], :cfg)

      # Analyze call graph across modules.
      Argus.analyze([Enum, :lists], :callgraph)

      # Run custom Datalog rules.
      Argus.analyze([MyApp.Worker], custom: "path/to/rules.dl")

  ## Architecture

  Layer 1 (generic) walks every BEAM instruction and emits base facts about
  instructions, registers, control flow, and calls. Layer 2 (domain extractors)
  produces higher-level semantic facts by interpreting OTP patterns, supervision
  trees, and other BEAM-specific constructs.

  Both layers feed into Souffle, which evaluates Datalog rules and returns
  derived relations as results.
  """
end
