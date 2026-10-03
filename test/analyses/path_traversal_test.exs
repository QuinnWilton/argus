defmodule Argus.Analyses.PathTraversalTest do
  use ExUnit.Case, async: true
  alias Argus.Test.Fixtures.PathTraversal
  alias Argus.Test.Memo

  test "upload entry filenames reach filesystem path positions through joins and normalization" do
    {:ok, results} = Memo.analyze([PathTraversal], :unsafe_input)
    funcs = for [_, func, _, _, _] <- results["upload_filename_path_traversal"], do: func

    for name <- [
          "unsafe",
          "unsafe_helper",
          "wrong_value",
          "partial",
          "opaque_branch",
          "late",
          "expanded",
          "basename_as_directory",
          "directory_removal",
          "mixed_positions"
        ] do
      assert Enum.any?(funcs, &String.contains?(&1, ":-#{name}/")), name
    end
  end
end
