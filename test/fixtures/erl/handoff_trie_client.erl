%% The program's client of handoff_trie: it asks for updates, and for
%% nothing else.
-module(handoff_trie_client).
-export([subscribed/1]).

subscribed(Topic) -> handoff_trie:update(Topic, 1).
