%% Joins restart_cast_keeper once, by a cast from the handle_info/2
%% clause for the message only its init/1 sends itself.
-module(restart_cast_info_user).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    self() ! join,
    {ok, nil}.

handle_info(join, State) ->
    gen_server:cast(restart_cast_keeper, {join, self()}),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
