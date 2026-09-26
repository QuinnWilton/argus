%% Joins restart_cast_keeper once, by a cast from the handle_continue/2
%% clause its init/1 continues to.
-module(restart_cast_cont_user).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_continue/2]).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) -> {ok, nil, {continue, join}}.

handle_continue(join, State) ->
    gen_server:cast(restart_cast_keeper, {join, self()}),
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
