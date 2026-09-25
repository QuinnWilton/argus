%% OTP's tuple child specs, the form Erlang supervisors still write
%% (zotonic's zotonic_core_sup, ejabberd's, mongooseim's):
%% {Id, {M, F, A}, Restart, Shutdown, Type, Modules}.
%%
%% init(literal) returns them as one literal list; init(runtime) builds
%% the list at run time around a spec whose arguments are computed, as
%% zotonic_core_sup does with its ring buffers; init(wrapped) starts
%% children through a wrapper of its own, naming the child only in the
%% modules list, as mongooseim's ejabberd_sup does, once with the module
%% literal and once from a helper's parameter the bytecode cannot show.
-module(tuple_spec_sup).
-behaviour(supervisor).

-export([start_link/1, init/1, start_wrapped/2]).

start_link(Kind) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Kind).

init(literal) ->
    {ok, {{one_for_one, 5, 10},
          [{first, {tuple_spec_first, start_link, []}, permanent, 5000, worker, [tuple_spec_first]},
           {pool, {tuple_spec_pool_sup, start_link, []}, permanent, infinity, supervisor, dynamic},
           {last, {tuple_spec_last, start_link, []}, transient, 5000, worker, [tuple_spec_last]}]}};
init(runtime) ->
    Size = application:get_env(tuple_spec, size, 10),
    {ok, {{one_for_one, 5, 10},
          [{first, {tuple_spec_first, start_link, []}, permanent, 5000, worker, [tuple_spec_first]},
           {buffer, {tuple_spec_buffer, start_link, [Size]}, permanent, 5000, worker, [tuple_spec_buffer]},
           {last, {tuple_spec_last, start_link, []}, temporary, 5000, worker, [tuple_spec_last]}]}};
init(wrapped) ->
    {ok, {{one_for_one, 5, 10},
          [{first, {?MODULE, start_wrapped, [tuple_spec_first, []]}, permanent, 5000, worker,
            [tuple_spec_first]},
           worker_spec(tuple_spec_last)]}}.

worker_spec(Mod) ->
    {Mod, {?MODULE, start_wrapped, [Mod, []]}, permanent, 5000, worker, [Mod]}.

start_wrapped(Mod, Args) ->
    Mod:start_link(Args).
