%% Tuple specs whose restart does not bring a table's owner back every time
%% (temporary, transient), and two built by a helper from its parameter
%% (called twice, so the compiler cannot fold the parameter into a
%% literal): the bytecode names no child there.
-module(tuple_restart_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{temp, {tuple_temp_owner, start_link, []}, temporary, 5000, worker, [tuple_temp_owner]},
           {trans, {tuple_transient_owner, start_link, []}, transient, 5000, worker,
            [tuple_transient_owner]},
           worker_spec(tuple_param_owner),
           worker_spec(tuple_param_other)]}}.

worker_spec(Mod) ->
    {Mod, {Mod, start_link, []}, permanent, 5000, worker, [Mod]}.
