%% Tuple specs a local helper builds from its parameters, the shape
%% ejabberd_sup (worker/1, supervisor/1 through supervisor/2) and
%% mnesia_kernel_sup (worker_spec/3, whose modules list is `[Name] ++
%% Modules`) write. Each helper is called more than once with different
%% arguments, so the compiler cannot fold a parameter into a literal: the
%% reader binds it to the call's argument. A module or a restart the
%% helper is handed from a call it cannot follow (configured_owner/0)
%% names no child, and the list is open.
-module(spec_helper_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [worker('Elixir.Argus.Test.Fixtures.ChildSpecs.HelperOwner'),
           worker_spec('Elixir.Argus.Test.Fixtures.ChildSpecs.ModulesOwner', 3000, [gen_server]),
           supervisor(spec_helper_child_sup),
           restart_spec('Elixir.Argus.Test.Fixtures.ChildSpecs.HelperTempOwner', temporary),
           worker(configured_owner()),
           worker_spec(spec_helper_last, 5000, []),
           restart_spec(spec_helper_restarted, permanent),
           supervisor(spec_helper_named_sup, spec_helper_other_sup)]}}.

worker(Mod) ->
    {Mod, {Mod, start_link, []}, permanent, 5000, worker, [Mod]}.

worker_spec(Name, KillAfter, Modules) ->
    {Name, {Name, start_link, []}, permanent, KillAfter, worker, [Name] ++ Modules}.

supervisor(Mod) ->
    supervisor(Mod, Mod).

supervisor(Name, Mod) ->
    {Name, {Mod, start_link, []}, permanent, infinity, supervisor, [Mod]}.

restart_spec(Mod, Restart) ->
    {Mod, {Mod, start_link, []}, Restart, 5000, worker, [Mod]}.

configured_owner() ->
    application:get_env(spec_helper, owner, 'Elixir.Argus.Test.Fixtures.ChildSpecs.EnvOwner').
