%% A keeper that keeps each registrant in its state record, with no
%% monitor, and a registrant that registers from init/1, under
%% one_for_one (clientlib/restart_state.dl; test/soundness/coupling_test.exs).
-module(restart_record_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{restart_record_keeper, {restart_record_keeper, start_link, []},
            permanent, 5000, worker, [restart_record_keeper]},
           {restart_record_user, {restart_record_user, start_link, []},
            permanent, 5000, worker, [restart_record_user]}]}}.
