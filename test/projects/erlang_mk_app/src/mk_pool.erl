-module(mk_pool).
-behaviour(gen_server).

-export([start_link/0, checkout/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

checkout() ->
    gen_server:call(?MODULE, checkout, infinity).

init([]) ->
    {ok, #{workers => []}}.

handle_call(checkout, _From, State) ->
    Worker = spawn(fun mk_dep:work/0),
    {reply, {ok, Worker}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
