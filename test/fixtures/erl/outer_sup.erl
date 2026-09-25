%% Starts dual_sup as a transient child.
-module(outer_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{dual, {dual_sup, start_link, []}, transient, infinity, supervisor, [dual_sup]}]}}.
