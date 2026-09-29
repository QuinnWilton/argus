%% A membership test as Elixir 1.20 compiles `x in list` over a list known
%% only at run time: 'Elixir.Enum':'__in__'(X, List), the element first.
%% Elixir 1.19 called 'Elixir.Enum':'member?'(List, X). safe_to_atom/2 is
%% the Elixir fixture's Taint.Allow, and handle_event/3 its only caller,
%% handing it a literal list.
-module(param_flow_enum_in).
-export([safe_to_atom/2, handle_event/3]).

safe_to_atom(Binary, Allowed) when is_binary(Binary) ->
    case 'Elixir.Enum':'__in__'(Binary, Allowed) of
        true -> binary_to_atom(Binary);
        _ -> nil
    end;
safe_to_atom(_Binary, _Allowed) ->
    nil.

handle_event(<<"sort">>, #{<<"sort">> := Sort}, Socket) ->
    _ = safe_to_atom(Sort, [<<"name">>, <<"recent_downloads">>, <<"inserted_at">>]),
    {noreply, Socket}.
