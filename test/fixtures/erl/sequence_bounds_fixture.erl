-module(sequence_bounds_fixture).
-export([bounded/1, unbounded/1, unicode_singleton/1, mixed/2, wrong_field/1,
         unchecked_tail/1, float_range/1, exported_builder/2, captured/1,
         unknown_alphabet/1, unchecked_return/2, exception_value/1,
         guard_other_copy/2, saved_value/2, partial_tuple/2, guard_alternatives/1,
         broad_alternative/1, fractional_only/1, unicode_range/1]).

%% Numeric guards deliberately admit floats. Successful list_to_atom calls do not.
bounded(Input) ->
    {ok, Name, _Rest, _Line, _Column, _Scope, _Tokens} = scan(Input, [], 1, 1, scope, []),
    route(Name).
scan([C | Tail], Acc, Line, Col, Scope, Tokens) when C >= $A, C =< $Z ->
    scan(Tail, [C | Acc], Line, Col, Scope, Tokens);
scan(Rest, Acc, Line, Col, Scope, Tokens) ->
    {ok, lists:reverse(Acc), Rest, Line, Col, Scope, Tokens}.
route(Name) -> leaf(Name).
leaf(Name) ->
    [_ | Tail] = Name,
    case Tail of [] -> list_to_atom("kind_" ++ Name); _ -> too_long end.

unbounded(Input) ->
    {ok, Name, _, _, _, _, _} = scan(Input, [], 1, 1, scope, []),
    list_to_atom("kind_" ++ Name).
unicode_singleton([C]) -> list_to_atom("unicode_" ++ [C]).
mixed(Input, Other) ->
    {ok, Name, _, _, _, _, _} = scan(Input, [], 1, 1, scope, []),
    case Other of use_name -> mixed_leaf(Name); _ -> mixed_leaf(Other) end.
mixed_leaf([_] = Name) -> list_to_atom("mixed_" ++ Name).
wrong_field(Input) ->
    {ok, _Name, Rest, _, _, _, _} = scan(Input, [], 1, 1, scope, []),
    case Rest of [_] -> list_to_atom("rest_" ++ Rest); _ -> error end.
unchecked_tail(Input) ->
    {ok, Name, _, _, _, _, _} = scan(Input, [], 1, 1, scope, []),
    list_to_atom(Name).
float_range([C]) when C >= 65.25, C =< 66.75 ->
    list_to_atom([C]).
exported_builder(Input, Acc) ->
    {ok, Name, _, _, _, _, _} = scan_exported(Input, Acc),
    case Name of [_] -> list_to_atom(Name); _ -> error end.
scan_exported([C | T], A) when C >= $A, C =< $Z -> scan_exported(T, [C | A]);
scan_exported(Rest, A) -> {ok, lists:reverse(A), Rest, 1, 1, scope, []}.
captured(Input) -> {Input, fun escaped_builder/1}.
escaped_builder([_] = Name) -> list_to_atom(Name).
unknown_alphabet(Input) ->
    Name = collect_any(Input, []),
    case Name of [_] -> list_to_atom(Name); _ -> error end.
collect_any([C | T], A) -> collect_any(T, [C | A]);
collect_any([], A) -> lists:reverse(A).
unchecked_return(Input, Choice) ->
    Name = case Choice of safe -> element(2, scan(Input, [], 1, 1, scope, [])); _ -> Input end,
    case Name of [_] -> list_to_atom(Name); _ -> error end.
exception_value(Input) ->
    Name = try unmodeled_scanner:scan(Input) catch _:Reason -> Reason end,
    case Name of [_] -> list_to_atom(Name); _ -> error end.

%% Guarding a separate value or a saved copy never bounds another argument.
guard_other_copy([C], [Other]) when C >= $A, C =< $Z -> list_to_atom([Other]).
saved_value(Input, Other) ->
    {ok, Name, _, _, _, _, _} = scan(Input, [], 1, 1, scope, []),
    Saved = Other,
    alias_barrier:observe(Name),
    case Name of [_] -> list_to_atom(Saved); _ -> error end.
partial_tuple(Input, Mode) ->
    {ok, Name, _, _, _, _, _} = partial_return(Input, Mode),
    case Name of [_] -> list_to_atom(Name); _ -> error end.
partial_return(Input, safe) -> scan(Input, [], 1, 1, scope, []);
partial_return(Input, _) -> {ok, Input, [], 1, 1, scope, []}.

%% Disjoint numeric alternatives retain their integer-character alphabet.
guard_alternatives([C]) when C >= $A, C =< $Z; C >= $0, C =< $9 ->
    list_to_atom([C]).
broad_alternative([C]) when C >= $A, C =< $Z; is_integer(C) ->
    list_to_atom([C]).
fractional_only([C]) when C > 65.1, C < 65.9 -> list_to_atom([C]).
unicode_range([C]) when C >= 0, C =< 16#10ffff -> list_to_atom([C]).
