%% PADL 2010, Sect. 3.1: "Similar problems exist in code that uses a
%% call to the registered built-in to make a decision whether to register
%% some process under a name or not, although such code is considerably
%% less common." The paper gives no code; this is the shape it describes.
-module(padl2010_registered).

-export([register_if_free/1]).

register_if_free(Name) ->
    case lists:member(Name, registered()) of
        false -> register(Name, self());
        true -> already_registered
    end.
