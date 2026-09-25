%% A generated parser's shape: yecc copies its runtime from OTP's
%% yeccpre.hrl into the parser, behind a -file attribute naming the
%% header. Its catch-alls are OTP's; the module's own, and those of a
%% header of the program's own, are the program's.
-module(header_catchall).
-export([parse/1, own/1, from_own_header/1]).

own(F) ->
    try F() catch _:_ -> error end.

parse(Token) -> yecctoken_to_string(Token).

-file("/usr/local/lib/erlang/lib/parsetools-2.6/include/yeccpre.hrl", 148).
yecctoken_to_string(Token) ->
    try erl_scan:text(Token) of
        undefined -> yecctoken2string(Token);
        Txt -> Txt
    catch _:_ -> yecctoken2string(Token)
    end.

yecctoken2string(Other) ->
    io_lib:format("~tp", [Other]).

-file("include/header_catchall.hrl", 3).
from_own_header(F) ->
    try F() catch _:_ -> error end.

-file("test/fixtures/erl/header_catchall.erl", 30).
