defmodule Argus.DlWarningsTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle

  @moduletag :souffle
  @moduletag :tmp_dir

  @tag timeout: 120_000
  test "shipped analyses and stages compile without warnings", %{tmp_dir: dir} do
    dl = Argus.Dl.root()

    programs =
      Path.wildcard(Path.join(dl, "analyses/*.dl")) ++
        Enum.map(~w(stage0.dl points_to.dl points_to_bounded.dl), &Path.join(dl, &1))

    # Runtime calls suppress warnings. Generate C++ with warnings enabled here:
    # this checks the full program without input facts or a C++ compiler.
    results =
      Task.async_stream(
        programs,
        fn program ->
          generated = Path.join(dir, Path.basename(program, ".dl") <> ".cpp")

          {diagnostics, status} =
            System.cmd(Souffle.executable(), ["--warn=all", "-g", generated, program],
              stderr_to_stdout: true
            )

          {Path.relative_to(program, dl), status, diagnostics}
        end,
        max_concurrency: 4,
        timeout: 120_000
      )

    Enum.each(results, fn {:ok, {program, status, diagnostics}} ->
      assert status == 0, "#{program} failed to compile:\n#{diagnostics}"
      assert diagnostics == "", "#{program} emitted diagnostics:\n#{diagnostics}"
    end)
  end
end
