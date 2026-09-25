-module(soundness_wrapper).
%% A GenServer wrapper argus's behaviour table does not list, standing for
%% rabbit's gen_server2: its servers answer calls with handle_call/3 and
%% take their other messages in handle_info/2, as gen_server's do.
-callback init(Args :: term()) -> {ok, State :: term()}.
-callback handle_call(Request :: term(), From :: term(), State :: term()) -> term().
-callback handle_cast(Request :: term(), State :: term()) -> term().
-callback handle_info(Info :: term(), State :: term()) -> term().
-optional_callbacks([handle_cast/2, handle_info/2]).
