%% An application whose start/2 starts its root supervisor, the Erlang
%% shape of an Elixir Application starting its tree inline.
-module(root_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    root_app_sup:start_link().

stop(_State) ->
    ok.
