%% Invalidates restart_reset_keeper's cache once, from init/1.
-module(restart_reset_user).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    restart_reset_keeper:invalidate(),
    {ok, nil}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
