%% restart_cast_keeper and a user that joins it from handle_continue/2,
%% under one_for_one (clientlib/restart_state.dl).
-module(restart_cast_cont_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{restart_cast_keeper, {restart_cast_keeper, start_link, []},
            permanent, 5000, worker, [restart_cast_keeper]},
           {restart_cast_cont_user, {restart_cast_cont_user, start_link, []},
            permanent, 5000, worker, [restart_cast_cont_user]}]}}.
