%% mnesia_controller's shape: its terminate/2 hands the reason to
%% reason_monitor:terminate_proc/3, which waits on the monitor only for
%% a crash. A one_for_all restart stops this server with shutdown after
%% the monitor crashed: the call then only logs.
-module(reason_controller).
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
    reason_monitor:terminate_proc(?MODULE, Reason, State).
