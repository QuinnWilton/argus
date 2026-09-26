%% ejabberd_sql_sup's shape: a supervisor that declares no behaviour and
%% starts itself with supervisor:start_link/3. Its tree puts bless_caller,
%% whose init/1 calls bless_callee, before bless_callee.
-module(bless_bare_sup).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 1, 5}, [worker(bless_caller), worker(bless_callee)]}}.

worker(Mod) ->
    {Mod, {Mod, start_link, []}, permanent, 5000, worker, [Mod]}.
