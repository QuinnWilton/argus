%% Children a start_child adds to a supervisor with a spec it states, as
%% dets_server's ensure_started/0 adds itself to kernel_safe_sup. The spec
%% is read as a child list's element is: a tuple spec, a map spec with no
%% restart (permanent by the supervisor's default), a temporary one. A
%% spec whose module is the function's parameter, one whose restart comes
%% from a call, and a simple_one_for_one template's argument list name
%% no child a supervisor restarts.
-module(spec_start_child).

-export([ensure/0, ensure_map/0, ensure_temp/0, ensure_param/0, add/1, ensure_restart/0,
         template/0]).

ensure() ->
    Spec = {spec_added, {'Elixir.Argus.Test.Fixtures.ChildSpecs.AddedOwner', start_link, []},
            permanent, 2000, worker, ['Elixir.Argus.Test.Fixtures.ChildSpecs.AddedOwner']},
    supervisor:start_child(kernel_safe_sup, Spec).

ensure_map() ->
    supervisor:start_child(kernel_safe_sup,
                           #{id => spec_added_map,
                             start => {'Elixir.Argus.Test.Fixtures.ChildSpecs.AddedMapOwner', start_link, []}}).

ensure_temp() ->
    supervisor:start_child(kernel_safe_sup,
                           {spec_added_temp,
                            {'Elixir.Argus.Test.Fixtures.ChildSpecs.AddedTempOwner', start_link, []},
                            temporary, 2000, worker,
                            ['Elixir.Argus.Test.Fixtures.ChildSpecs.AddedTempOwner']}).

ensure_param() ->
    add('Elixir.Argus.Test.Fixtures.ChildSpecs.AddedParamOwner').

add(Mod) ->
    supervisor:start_child(kernel_safe_sup, {Mod, {Mod, start_link, []}, permanent, 2000, worker, [Mod]}).

ensure_restart() ->
    supervisor:start_child(kernel_safe_sup,
                           #{id => spec_added_dyn,
                             start => {'Elixir.Argus.Test.Fixtures.ChildSpecs.AddedDynOwner', start_link, []},
                             restart => restart()}).

restart() ->
    application:get_env(spec_start_child, restart, permanent).

template() ->
    supervisor:start_child(spec_template_sup, [self()]).
