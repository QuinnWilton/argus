%% The worker whose members/0 reads the supervisor's table from its
%% callers (excl_ets_embed_app has the whole shape).
-module(excl_ets_embed_worker).
-behaviour(gen_server).
-export([start_link/0, members/0, init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, excl_ets_embed_worker}, excl_ets_embed_worker, [], []).
members() -> ets:tab2list(excl_ets_embed_members).

init([]) ->
    ets:insert(excl_ets_embed_members, {node(), self()}),
    {ok, #{}}.
handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
