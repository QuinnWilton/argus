%% An application whose start/2 starts rows_root_sup, its root supervisor.
-module(rows_root_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    rows_root_sup:start_link().

stop(_State) ->
    ok.
