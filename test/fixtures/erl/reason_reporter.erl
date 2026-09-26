%% reason_controller's twin: the monitor's API it hands the reason to
%% waits for shutdown, so the one_for_all restart after the monitor's
%% crash calls the monitor that is gone.
-module(reason_reporter).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    reason_monitor:farewell_proc(?MODULE, Reason, State).
