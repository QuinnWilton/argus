-module(telemetry).

%% A stand-in for telemetry 0.4.3: execute/3 is not the escript's, and
%% fixture_version/0 is in no telemetry argus carries.
-export([execute/3, fixture_version/0]).

-spec execute([atom()], map(), map()) -> ok.
execute(_Event, _Measurements, _Metadata) ->
    ok.

-spec fixture_version() -> {fixture, string()}.
fixture_version() ->
    {fixture, "0.4.3"}.
