%% Lookup-then-start pairs whose loser is not a bug, and one that is.
%%
%% server_init/0 is inet_gethost_native's: the register is inside an
%% Erlang catch, and the loser exits with already_started on purpose.
%% switch/0 is ssh_dbg's: the loser's {error, {already_started, Pid}}
%% is dropped on the way back (start/0 ignores start_server/0's result),
%% and what follows goes by the name the winner holds. ensure/0 hands
%% the start's answer to its callers, who may match {ok, Pid} on it.
-module(registry_losers).
-behaviour(gen_server).
-export([server_init/0, switch/0, start/0, start_server/0, ensure/0]).
-export([init/1, handle_call/3, handle_cast/2]).

server_init() ->
    case whereis(?MODULE) of
        undefined ->
            case (catch register(?MODULE, self())) of
                true -> ok;
                _ -> exit({already_started, whereis(?MODULE)})
            end;
        Winner ->
            exit({already_started, Winner})
    end.

switch() ->
    case whereis(?MODULE) of
        undefined -> start();
        _ -> ok
    end,
    gen_server:call(?MODULE, switch).

start() ->
    start_server(),
    ok.

start_server() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

ensure() ->
    case whereis(?MODULE) of
        undefined -> start_server();
        Pid -> {ok, Pid}
    end.

init([]) -> {ok, #{}}.
handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
