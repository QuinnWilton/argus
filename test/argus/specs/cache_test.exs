defmodule Argus.Specs.CacheTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Specs
  alias Argus.Test.Peer

  @moduletag :tmp_dir

  test "recent equal-size replacements cannot hide behind preserved timestamps", %{tmp_dir: dir} do
    path = Path.join(dir, "same-size.beam")
    File.write!(path, "AAAA")
    File.touch!(path, 1_600_000_000)
    before = Specs.Source.file_stamp(path)
    File.write!(path, "BBBB")
    File.touch!(path, 1_600_000_000)
    refute before == Specs.Source.file_stamp(path)
  end

  test "warm declarations replay transitive type reads and observe remote-only edits", %{
    tmp_dir: dir
  } do
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true, debug_info: true)

      compile = fn source, timestamp ->
        for {module, beam} <- Code.compile_string(source) do
          path = Path.join(dir, "#{module}.beam")
          File.write!(path, beam)
          File.touch!(path, timestamp)
        end
      end

      compile.("defmodule SpecsCacheRemote do @type t :: :ok end", 1_600_000_000)
      compile.("defmodule SpecsCacheMiddle do @type t :: SpecsCacheRemote.t() end", 1_600_000_000)

      compile.(
        "defmodule SpecsCacheAPI do @spec result() :: SpecsCacheMiddle.t(); def result, do: :ok end",
        1_600_000_000
      )

      source = Specs.Source.new([dir])

      read = fn ->
        memo = :ets.new(:specs_cache_test, [:set, :public])
        :ets.insert(memo, {:specs_source, source})

        try do
          value = Specs.installed(SpecsCacheAPI, memo)
          assert :ets.member(memo, {:types, SpecsCacheMiddle})
          assert :ets.member(memo, {:types, SpecsCacheRemote})
          value[{:result, 0}]
        after
          :ets.delete(memo)
        end
      end

      assert read.() == [:total, :constant]
      assert read.() == [:total, :constant]
      compile.("defmodule SpecsCacheRemote do @type t :: :error end", 1_600_000_010)
      assert read.() == [:can_fail, :constant]
      assert read.() == [:can_fail, :constant]
      compile.("defmodule SpecsCacheRemote do @type t :: :ok end", 1_600_000_020)
      assert read.() == [:total, :constant]
    end)
  end
end
