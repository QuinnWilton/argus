defmodule Argus.Soundness.PathTraversalTest do
  use ExUnit.Case, async: true
  alias Argus.Test.Fixtures.PathTraversal
  alias Argus.Test.Memo

  @tag :souffle
  test "the actual filename's basename as final file component is protected" do
    {:ok, results} = Memo.analyze([PathTraversal], :unsafe_input)
    funcs = for [_, func, _, _, _] <- results["upload_filename_path_traversal"], do: func

    for name <- [
          "safe",
          "safe_helper",
          "wrong_field",
          "wrong_root",
          "fixed_name",
          "generated_name",
          "ordinary_config"
        ] do
      refute Enum.any?(
               funcs,
               &(String.contains?(&1, ":-#{name}/") or String.ends_with?(&1, ":#{name}/2"))
             ),
             name
    end
  end

  @tag :tmp_dir
  test "file-leaf copies reject a dot or dot-dot directory destination", %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    base = Path.join(dir, "base")
    File.write!(source, "content")
    File.mkdir!(base)

    for name <- [".", ".."] do
      assert {:error, :eisdir} = File.cp(source, Path.join(base, Path.basename(name)))
    end
  end
end
