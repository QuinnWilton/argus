Code.require_file("clock_calls.exs", __DIR__)

# Compile only this tutorial's source and analyze the resulting bytecode.
# No application function is executed and no external ebin is added to the VM.
beams =
  "fixtures.exs"
  |> Path.expand(__DIR__)
  |> Code.compile_file()
  |> Enum.map(fn {_module, beam} -> beam end)

destination = System.get_env("ARGUS_TUTORIAL_BUNDLE", "tmp/clock")
rules = Path.join(__DIR__, "clock.dl")

bundle =
  Argus.Debug.capture!(beams, {:custom, rules}, destination,
    extractors: [Argus.Examples.ClockCalls]
  )

table = Argus.Debug.rows!(bundle, "clock_use")

unless match?([[_site, "Argus.Examples.WallClock:now/0"]], table.rows) do
  raise "expected the wall clock alone, got: #{inspect(table.rows)}"
end

findings = Argus.Findings.build(Argus.Examples.ClockUses, %{"clock_use" => table.rows})

IO.puts("Captured #{bundle}")
IO.write(Argus.Tsv.encode([table.fields | table.rows]))

for finding <- findings do
  location = Argus.Debug.locate!(bundle, Argus.InstrId.format(finding.instr))
  IO.puts("#{finding.severity}: #{finding.title} at #{location.file}:#{location.line}")
end

%{bundle: bundle, findings: findings}
