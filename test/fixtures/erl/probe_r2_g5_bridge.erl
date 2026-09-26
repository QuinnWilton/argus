-module(probe_r2_g5_bridge).
-behaviour(supervisor_bridge).
%% A supervisor_bridge process owns a named table others read; the bridge
%% dies with the subsystem it wraps, and the table with it.
-export([start_link/0, init/1, terminate/2, lookup/1]).

start_link() -> supervisor_bridge:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(probe_g5_bridge_tab, [named_table, public, set]),
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    {ok, Pid, #{pid => Pid}}.

terminate(_Reason, #{pid := Pid}) -> Pid ! stop, ok.

lookup(K) -> ets:lookup(probe_g5_bridge_tab, K).
