%% An application whose start/2 starts a table's owner, a worker, directly.
-module(worker_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    worker_owner:start_link().

stop(_State) ->
    ok.
