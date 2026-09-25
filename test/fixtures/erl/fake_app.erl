%% A start/2 that is no Application's callback: what it starts is no root.
-module(fake_app).

-export([start/2]).

start(_Type, _Args) ->
    fake_root_sup:start_link().
