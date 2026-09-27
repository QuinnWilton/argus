-module(shop_notifier).
-behaviour(gen_server).

-export([start_link/0, listen/1, notify/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

listen(Pid) ->
    gen_server:call(?MODULE, {listen, Pid}).

notify(Event) ->
    gen_server:cast(?MODULE, {notify, Event}).

init([]) ->
    {ok, #{listeners => []}}.

%% The listener lives in this server's state: a restart forgets it.
handle_call({listen, Pid}, _From, #{listeners := Listeners} = State) ->
    {reply, ok, State#{listeners := [Pid | Listeners]}}.

handle_cast({notify, Event}, #{listeners := Listeners} = State) ->
    [Pid ! {shop_event, Event} || Pid <- Listeners],
    {noreply, State}.
