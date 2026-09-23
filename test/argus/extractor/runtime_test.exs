defmodule Argus.Extractor.RuntimeTest do
  use ExUnit.Case, async: true

  doctest Argus.Extractor.Runtime

  alias Argus.Extractor.Runtime

  test "the preloaded modules are the runtime" do
    assert Runtime.module?(:erlang)
    assert Runtime.module?(:erts_internal)
  end

  test "an OTP application outside the core set is program code" do
    refute Runtime.module?(:ssl)
    refute Runtime.module?(:mnesia)
  end
end
