%% The code Fig. 2 (right) of PADL 2010 was taken from, as it reads in
%% OTP's lib/snmp/src/agent/snmp_shadow_table.erl: dirty_read/1 on a
%% {Table, Key} tuple, and a write whose key is spelled out.
%% create_time_stamp_table/0 is verbatim; table_func/2 is cut down to the
%% call that reaches it, and create_table/4 to one mnesia call.
-module(padl2010_snmp_shadow_table).

-export([table_func/2]).

-record(time_stamp, {key, data}).

table_func(new, _NameDb) ->
    create_time_stamp_table(),
    true;
table_func(delete, _NameDb) ->
    true.

create_time_stamp_table() ->
    Props = [{type, set},
             {attributes, record_info(fields, time_stamp)}],
    create_table(time_stamp, Props, ram_copies, false),
    NRef =
        case mnesia:dirty_read({time_stamp, ref_count}) of
            [] -> 1;
            [#time_stamp{data = Ref}] -> Ref + 1
        end,
    ok = mnesia:dirty_write(#time_stamp{key = ref_count, data = NRef}).

create_table(Name, Props, Storage, _Local) ->
    mnesia:create_table(Name, [{Storage, [node()]} | Props]).
