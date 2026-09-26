%% The library's top supervisor: it creates the members table in init/1
%% (excl_ets_embed_app has the whole shape).
-module(excl_ets_embed_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, excl_ets_embed_sup}, excl_ets_embed_sup, []).

init([]) ->
    ets:new(excl_ets_embed_members, [named_table, public, set]),
    {ok, {#{strategy => one_for_one},
          [#{id => excl_ets_embed_worker, start => {excl_ets_embed_worker, start_link, []}}]}}.
