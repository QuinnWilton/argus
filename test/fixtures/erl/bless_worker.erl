-module(bless_worker).

-export([init/1, handle_call/3, handle_cast/2]).

init(Opts) ->
    {ok, Opts}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
