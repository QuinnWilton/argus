%% mnesia_monitor's shape: its terminate_proc/3, called from every
%% server's terminate/2, reports a crash by waiting on this server and
%% only logs a stop (shutdown, killed). farewell_proc/3 is the twin that
%% waits for shutdown.
-module(reason_monitor).
-behaviour(gen_server).

-export([start_link/0, terminate_proc/3, farewell_proc/3]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

terminate_proc(Who, R, State) when R /= shutdown, R /= killed ->
    fatal({Who, R, State});
terminate_proc(Who, Reason, _State) ->
    logger:info("~p terminated: ~p", [Who, Reason]),
    ok.

farewell_proc(Who, shutdown, _State) ->
    gen_server:call(?MODULE, {farewell, Who}, infinity);
farewell_proc(_Who, _Reason, _State) ->
    ok.

fatal(Info) ->
    gen_server:call(?MODULE, {fatal, Info}, infinity).

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    terminate_proc(?MODULE, Reason, State).
