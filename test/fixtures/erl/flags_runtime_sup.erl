%% A supervisor whose flags tuple is built at run time, as
%% mnesia_kernel_sup's `{one_for_all, 0, timer:hours(24)}` is: the
%% strategy is still the literal first element (test/extractors/
%% supervision_test.exs).
-module(flags_runtime_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = {one_for_all, 0, timer:hours(24)},
    {ok, {Flags, [{flags_runtime_child, {flags_runtime_child, start_link, []},
                   permanent, 5000, worker, [flags_runtime_child]}]}}.
