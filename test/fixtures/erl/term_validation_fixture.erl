-module(term_validation_fixture).
-export([decode/1, wrong_value/2, ignored/1, accepting_error/1, caught_error/1,
         partial/2, premature_use/1, without_safe/1, shallow/1, missing_head/1,
         missing_tail/1, partial_tuple/1, missing_map_value/1, ignored_map_verdict/1,
         accept_port/1, unknown_consumer/1, nondecreasing_recursion/1,
         execute_decoded/1, apply_decoded/1, projected_tuple/1, projected_list/1,
         helper_execution/1, helper_consumption/1, throw_return/1,
         symbolic_equality/2, error_tuple_return/1, numeric_subtype/1,
         binary_subtype/1, returning_exit/1, caught_validator_reason/1, consumed_verdict/1, rejected_payload/1,
         mixed_copies/2]).

%% These helpers deliberately have no safety-signalling names. Their bytecode
%% must establish complete recursive validation of the accepted payload.
decode(Binary) ->
    try binary_to_term(Binary, [safe]) of
        Term -> case walk(Term) of ok -> {ok, Term}; {error, _} = Error -> Error end
    catch error:badarg -> {error, invalid_term} end.

%% One source line deliberately exercises compiler-copy deduplication: the
%% validated branch must not stand in for its unchecked sibling.
mixed_copies(Binary, Check) -> case Check of true -> T = binary_to_term(Binary, [safe]), case walk(T) of ok -> {ok, T}; E -> E end; _ -> binary_to_term(Binary, [safe]) end.

wrong_value(Binary, Other) ->
    Term = binary_to_term(Binary, [safe]),
    case walk(Other) of ok -> {ok, Term}; Error -> Error end.
ignored(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    walk(Term),
    {ok, Term}.
accepting_error(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case walk(Term) of ok -> {ok, Term}; _ -> {ok, Term} end.
caught_error(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    try case walk(Term) of ok -> {ok, Term}; Error -> throw(Error) end
    catch _:_ -> {ok, Term} end.
partial(Binary, Check) ->
    Term = binary_to_term(Binary, [safe]),
    case Check of true -> ok = walk(Term); false -> ok end,
    {ok, Term}.
premature_use(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    self() ! Term,
    case walk(Term) of ok -> {ok, Term}; Error -> Error end.
without_safe(Binary) ->
    Term = binary_to_term(Binary),
    case walk(Term) of ok -> {ok, Term}; Error -> Error end.
shallow(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case flat(Term) of ok -> {ok, Term}; Error -> Error end.
missing_head(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case tail_only(Term) of ok -> {ok, Term}; Error -> Error end.
missing_tail(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case head_only(Term) of ok -> {ok, Term}; Error -> Error end.
partial_tuple(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case almost_tuple(Term) of ok -> {ok, Term}; Error -> Error end.
missing_map_value(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case keys_only(Term) of ok -> {ok, Term}; Error -> Error end.
ignored_map_verdict(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case unchecked_fold(Term) of ok -> {ok, Term}; Error -> Error end.
accept_port(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case ports_ok(Term) of ok -> {ok, Term}; Error -> Error end.


unknown_consumer(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    unmodeled_term_consumer:consume(Term),
    case walk(Term) of ok -> {ok, Term}; Error -> Error end.
nondecreasing_recursion(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case repeated(Term) of ok -> {ok, Term}; Error -> Error end.
repeated(Term) ->
    case erlang:monotonic_time() of 0 -> ok; _ -> repeated(Term) end.


execute_decoded(Binary) ->
    Term = binary_to_term(Binary, [safe]), Term().
apply_decoded(Binary) ->
    Term = binary_to_term(Binary, [safe]), apply(Term, []).
projected_tuple(Binary) ->
    Term = binary_to_term(Binary, [safe]), element(1, Term).
projected_list(Binary) ->
    Term = binary_to_term(Binary, [safe]), hd(Term).
helper_execution(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case execute_first(Term) of ok -> {ok, Term}; Error -> Error end.
helper_consumption(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case consume_first(Term) of ok -> {ok, Term}; Error -> Error end.
throw_return(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    try throw(Term) catch throw:Caught -> Caught end.
symbolic_equality(Binary, Other) ->
    Term = binary_to_term(Binary, [safe]),
    case Term =:= Other of true -> Term; false -> {error, different} end.
error_tuple_return(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case Term of {error, _} -> Term; _ -> {error, different} end.
numeric_subtype(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case number_marker(Term) of ok -> {ok, Term}; Error -> Error end.
binary_subtype(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case binary_marker(Term) of ok -> {ok, Term}; Error -> Error end.
returning_exit(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case signal(Term) of ok -> {ok, Term}; _ -> Term end.
execute_first(Term) -> Term(), walk(Term).
consume_first(Term) -> unmodeled_term_consumer:consume(Term), walk(Term).
number_marker({Marker, _}) when is_number(Marker) ->
    case is_integer(Marker) of true -> ok; false -> {error, float} end;
number_marker(_) -> {error, other}.
binary_marker({Marker, _}) when is_bitstring(Marker) ->
    case is_binary(Marker) of true -> ok; false -> {error, bitstring} end;
binary_marker(_) -> {error, other}.
signal(Term) -> exit(self(), Term).


caught_validator_reason(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    try throwing_walk(Term) of ok -> {ok, Term}
    catch throw:{error, {unsafe, Value}} -> Value end.
throwing_walk(Term) ->
    case walk(Term) of ok -> ok; Error -> throw(Error) end.
rejected_payload(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case walk(Term) of ok -> Term; {error, {unsafe, Value}} -> Value() end.
consumed_verdict(Binary) ->
    Term = binary_to_term(Binary, [safe]),
    case walk(Term) of ok -> ok; Error -> unmodeled_term_consumer:consume(Error) end.

walk(Term) when is_list(Term) -> cells(Term);
walk(Term) when is_tuple(Term) -> slots(Term, tuple_size(Term));
walk(Term) when is_map(Term) -> pairs(Term);
walk(Term) when is_atom(Term); is_number(Term); is_bitstring(Term); is_pid(Term); is_reference(Term) -> ok;
walk(Term) -> {error, {unsafe, Term}}.
cells([]) -> ok;
cells([H | T]) when is_list(T) ->
    case walk(H) of ok -> cells(T); Error -> Error end;
cells([H | T]) ->
    case walk(H) of ok -> walk(T); Error -> Error end.
slots(_Tuple, 0) -> ok;
slots(Tuple, N) ->
    case walk(element(N, Tuple)) of ok -> slots(Tuple, N - 1); Error -> Error end.
pairs(Map) ->
    try maps:fold(fun(K, V, ok) ->
        case walk(K) of
            ok -> case walk(V) of ok -> ok; Error -> throw(Error) end;
            Error -> throw(Error)
        end
    end, ok, Map)
    catch throw:{error, _} = Error -> Error end.

flat(Term) when is_function(Term); is_port(Term) -> {error, unsafe};
flat(_) -> ok.
tail_only([]) -> ok;
tail_only([_H | T]) -> tail_only(T);
tail_only(Term) -> walk(Term).
head_only([H | _T]) -> walk(H);
head_only(Term) -> walk(Term).
almost_tuple(Term) when is_tuple(Term) -> slots(Term, tuple_size(Term) - 1);
almost_tuple(Term) -> walk(Term).
keys_only(Term) when is_map(Term) ->
    maps:fold(fun(K, _V, ok) -> case walk(K) of ok -> ok; E -> throw(E) end end, ok, Term);
keys_only(Term) -> walk(Term).
unchecked_fold(Term) when is_map(Term) ->
    maps:fold(fun(K, V, _) -> walk(K), walk(V), ok end, ok, Term);
unchecked_fold(Term) -> walk(Term).
ports_ok(Term) when is_port(Term) -> ok;
ports_ok(Term) -> walk(Term).
