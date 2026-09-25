%% vernemq's vmq_acl_reloader (and vmq_passwd_reloader), as of 2.2.1.
%%
%% handle_info(reload) re-arms the reload timer and drops its ref, so
%% the record's timer field keeps the ref init/1 armed, which fired long
%% ago. A config change cancels that stale ref and arms again: a second
%% reload loop beside the first, and one more on every change after.
-module(timer_loop_reloader).
-behaviour(gen_server).
-export([start_link/0, config_changed/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {file, interval = 0, timer}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

config_changed() ->
    gen_server:cast(?MODULE, config_changed).

init([]) ->
    {ok, init_state(#state{})}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(config_changed, State) ->
    {noreply, init_state(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reload, #state{file = File, interval = Interval} = State) ->
    ok = load_from_file(File),
    erlang:send_after(Interval, self(), reload),
    {noreply, State}.

init_state(State) ->
    case State#state.timer of
        undefined -> undefined;
        TRef -> erlang:cancel_timer(TRef)
    end,
    {ok, File} = application:get_env(timer_loop, file),
    {ok, Interval} = application:get_env(timer_loop, interval),
    ok = load_from_file(File),
    {NewI, NewTRef} =
        case Interval of
            0 ->
                {0, undefined};
            I ->
                IinMs = abs(I * 1000),
                NTRef = erlang:send_after(IinMs, self(), reload),
                {IinMs, NTRef}
        end,
    State#state{file = File, interval = NewI, timer = NewTRef}.

load_from_file(_File) ->
    ok.
