%% An application whose start/2 starts dual_sup, which another tree also
%% starts as a transient child: restarted there, it is no application root.
-module(dual_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    dual_sup:start_link().

stop(_State) ->
    ok.
