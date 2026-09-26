%% mnesia_kernel_sup's shape: one_for_all, flags built at run time, the
%% monitor first.
-module(reason_kernel_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = {one_for_all, 0, timer:hours(24)},
    {ok, {Flags, [worker(reason_monitor), worker(reason_controller), worker(reason_reporter)]}}.

worker(Mod) ->
    {Mod, {Mod, start_link, []}, permanent, 3000, worker, [Mod]}.
