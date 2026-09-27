-module(mk_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    mk_pool:start_link().

stop(_State) ->
    ok.
