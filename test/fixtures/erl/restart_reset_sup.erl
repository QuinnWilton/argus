%% A keeper whose cast resets a field of its state record to the value
%% its init/1 starts it at, cast from its sibling's init/1: a restart
%% loses nothing (test/soundness/coupling_test.exs, quiet).
-module(restart_reset_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{restart_reset_keeper, {restart_reset_keeper, start_link, []},
            permanent, 5000, worker, [restart_reset_keeper]},
           {restart_reset_user, {restart_reset_user, start_link, []},
            permanent, 5000, worker, [restart_reset_user]}]}}.
