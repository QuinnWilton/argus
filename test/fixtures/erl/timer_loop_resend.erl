%% MongooseIM's service_mongoose_system_metrics: while the last reporter
%% still runs, the tick kills it and hands itself the tick again with
%% `!`. The send is in the clause for `report`, the loop's own.
-module(timer_loop_resend).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

init([]) ->
    erlang:send_after(1000, self(), report),
    {ok, none}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(report, none) ->
    Pid = spawn(fun() -> ok end),
    erlang:send_after(60000, self(), report),
    {noreply, Pid};
handle_info(report, Pid) ->
    exit(Pid, kill),
    self() ! report,
    {noreply, none}.
