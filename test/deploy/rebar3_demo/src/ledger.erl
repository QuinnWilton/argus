%% Restores an entry from bytes a caller hands in, unchecked.
-module(ledger).

-export([restore/1]).

-spec restore(binary()) -> term().
restore(Bytes) ->
    binary_to_term(Bytes).
