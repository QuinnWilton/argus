%% inet_db's shape: a gen_server that declares no behaviour and starts
%% itself with gen_server:start_link/4. Its init/1 calls bless_later,
%% which its supervisor starts after it: the start deadlocks.
-module(bless_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = gen_server:call(bless_later, hello),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
