defmodule Argus.Extractor.CallSitesTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.CallSites

  @source """
  defmodule Argus.CallSitesTest.Elements do
    def each(urls), do: Enum.each(urls, &:httpc.request/1)
    def erlang(bins), do: :lists.map(&:erlang.binary_to_term/1, bins)
    def lambda(urls), do: Enum.each(urls, fn u -> :httpc.request(u) end)
    def local(xs), do: Enum.map(xs, &double/1)
    defp double(x), do: x * 2
  end
  """

  setup_all do
    [{mod, bin}] = Code.compile_string(@source)
    path = Path.join(System.tmp_dir!(), "#{mod}-#{System.unique_integer([:positive])}.beam")
    File.write!(path, bin)
    {:ok, data} = BeamSpy.BeamFile.disassemble(path)
    File.rm!(path)
    %{data: data}
  end

  test "a function handed by name to a call that runs it on each element is called there",
       %{data: data} do
    sites =
      for site <- CallSites.element_sites(data),
          do: {site.func_id |> String.split(":") |> List.last(), site.mfa, site.element, site.via}

    assert Enum.sort(sites) == [
             {"each/1", {:httpc, :request, 1}, {:x, 0}, {Enum, :each, 2}},
             {"erlang/1", {:erlang, :binary_to_term, 1}, {:x, 1}, {:lists, :map, 2}}
           ]
  end
end
