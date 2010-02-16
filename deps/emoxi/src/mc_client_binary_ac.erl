
% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_client_binary_ac).

-behavior(mc_client_ac).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_binary, [send/2, send/4, recv/2, encode/3]).

-export([cmd/5]).

-compile(export_all).

%% A memcached client that speaks binary protocol,
%% with an "API conversion" interface.

% cmd(version, Sock, RecvCallback, CBData, Entry) ->
%     send_recv(Sock, RecvCallback, #mc_header{opcode = ?VERSION}, Entry);

cmd(get, Sock, RecvCallback, CBData, Keys) when is_list(Keys) ->
    ok = send(Sock,
              lists:map(fun (K) -> encode(req,
                                          #mc_header{opcode = ?GETKQ},
                                          #mc_entry{key = K})
                        end,
                        Keys)),
    ok = send(Sock, req, #mc_header{opcode = ?NOOP}, #mc_entry{}),
    get_recv(Sock, RecvCallback, CBData);

cmd(gets, Sock, RecvCallback, CBData, Keys) when is_list(Keys) ->
    ok = send(Sock,
              lists:map(fun (K) -> encode(req,
                                          #mc_header{opcode = ?GETKQ},
                                          #mc_entry{key = K})
                        end,
                        Keys)),
    ok = send(Sock, req, #mc_header{opcode = ?NOOP}, #mc_entry{}),
    get_recv(Sock, RecvCallback, CBData);

cmd(set, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(Sock, RecvCallback, CBData, Entry, ?SET);
cmd(add, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(Sock, RecvCallback, CBData, Entry, ?ADD);
cmd(replace, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(Sock, RecvCallback, CBData, Entry, ?REPLACE);

cmd(append, Sock, RecvCallback, CBData, Entry) ->
    cmd_xpend(Sock, RecvCallback, CBData, Entry, ?APPEND);
cmd(prepend, Sock, RecvCallback, CBData, Entry) ->
    cmd_xpend(Sock, RecvCallback, CBData, Entry, ?PREPEND);

cmd(cas, Sock, RecvCallback, CBData, Entry) ->
    cmd_update(Sock, RecvCallback, CBData, Entry, ?SET);

cmd(incr, Sock, RecvCallback, CBData, Entry) ->
    cmd_arith(Sock, RecvCallback, CBData, Entry, ?INCREMENT);
cmd(decr, Sock, RecvCallback, CBData, Entry) ->
    cmd_arith(Sock, RecvCallback, CBData, Entry, ?DECREMENT);

cmd(delete, Sock, RecvCallback, CBData, Entry) ->
    send_recv(Sock, RecvCallback, CBData, #mc_header{opcode = ?DELETE}, Entry);

cmd(flush_all, Sock, RecvCallback, CBData ,Entry) ->
    send_recv(Sock, RecvCallback, CBData, #mc_header{opcode = ?FLUSH}, Entry);

cmd(stats, Sock, RecvCallback, CBData, Entry) ->
    ok = mc_binary:send(Sock, req,
                        #mc_header{opcode = ?STAT}, Entry),
    stat_recv(Sock, RecvCallback, CBData, #mc_header{opcode = ?STAT}, Entry);

cmd(Opcode, Sock, RecvCallback, CBData, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    mc_client_binary:cmd(Opcode, Sock, RecvCallback, CBData, Entry).

% -------------------------------------------------

% Calls binary target and converts binary opcode/success
% to ascii result string.
send_recv(Sock, RecvCallback, CBData, Header, Entry) ->
    {ok, #mc_header{opcode = O, status = S} = _RH, _RE, CD} =
        mc_binary:send_recv(Sock, RecvCallback, CBData, Header, Entry),
    {ok, mc_binary:b2a_code(O, S), CD}.

% -------------------------------------------------

cmd_update(Sock, RecvCallback, CBData,
           #mc_entry{flag = Flag, expire = Expire} = Entry, Opcode) ->
    Ext = <<Flag:32, Expire:32>>,
    send_recv(Sock, RecvCallback, CBData,
              #mc_header{opcode = Opcode}, Entry#mc_entry{ext = Ext}).

cmd_xpend(Sock, RecvCallback, CBData, Entry, Opcode) ->
    send_recv(Sock, RecvCallback, CBData,
              #mc_header{opcode = Opcode}, Entry#mc_entry{ext = undefined}).

cmd_arith(Sock, RecvCallback, CBData,
          #mc_entry{data = Amount, expire = Expire} = Entry, Opcode) ->
    case is_list(Amount) of
        true ->
            AmountN = list_to_integer(Amount),
            cmd_arith(Sock, RecvCallback, CBData,
                      Entry#mc_entry{data = <<AmountN:64>>}, Opcode);
        false ->
            Ext = <<Amount/binary, 0:64, Expire:32>>,
            send_recv(Sock, RecvCallback, CBData,
                      #mc_header{opcode = Opcode},
                      Entry#mc_entry{ext = Ext, data = undefined})
    end.

get_recv(Sock, RecvCallback, CBData) ->
    case recv(Sock, res) of
        {error, _} = Err -> Err;
        {ok, #mc_header{opcode = ?NOOP}, _Entry} ->
            {ok, <<"END\r\n">>, CBData};
        {ok, #mc_header{opcode = ?GETKQ} = Header, Entry} ->
            NCB = case is_function(RecvCallback) of
                      true  -> RecvCallback(Header, Entry, CBData);
                      false -> CBData
                  end,
            get_recv(Sock, RecvCallback, NCB)
    end.

stat_recv(Sock, RecvCallback, CBData, ReqHeader, ReqEntry) ->
    case recv(Sock, res) of
        {error, _} = Err -> Err;
        {ok, #mc_header{opcode = ?STAT,
                        status = ?SUCCESS},
             #mc_entry{key = undefined}} ->
            {ok, <<"END\r\n">>};
        {ok, #mc_header{opcode = ?STAT,
                        status = ?SUCCESS} = Header, Entry} ->
            NCB = case is_function(RecvCallback) of
                      true  -> RecvCallback(Header, Entry, CBData);
                      false -> CBData
                  end,
            stat_recv(Sock, RecvCallback, NCB, ReqHeader, ReqEntry);
        {ok, _, _} ->
            {ok, <<"ERROR\r\n">>}
    end.

% -------------------------------------------------

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    test_flush(Sock),
    (fun () ->
        {ok, RB, undefined} = cmd(set, Sock, undefined, undefined,
                                  #mc_entry{key = Key, data = <<"AAA">>}),
        ?assertMatch(RB, <<"STORED\r\n">>),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

test_flush(Sock) ->
    {ok, works, undefined} = mc_binary:send_recv(Sock, undefined, undefined,
                                                 #mc_header{opcode = ?FLUSH}, #mc_entry{},
                                                 works).

get_test_match(Sock, Key, Data) ->
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, RB, ok} = cmd(get, Sock,
                   fun (_H, E, undefined) ->
                       ets:update_counter(D, nvals, 1),
                       ?assertMatch(Key, E#mc_entry.key),
                       ?assertMatch(Data, E#mc_entry.data)
                   end, undefined,
                   [Key]),
    ?assertMatch(RB, <<"END\r\n">>),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

get_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB, _CD} = cmd(get, Sock,
                       fun (_H, _E, _X) -> ?assert(false) % Should not get here.
                       end, undefined,
                       [<<"ccc">>, <<"bbb">>]),
        ?assertMatch(RB, <<"END\r\n">>),
        ?assertMatch([{nvals, 0}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB, _X} = cmd(get, Sock,
                       fun (_H, E, _X) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(<<"aaa">>, E#mc_entry.key),
                           ?assertMatch(<<"AAA">>, E#mc_entry.data)
                       end, undefined,
                       [<<"aaa">>, <<"bbb">>]),
        ?assertMatch(RB, <<"END\r\n">>),
        ?assertMatch([{nvals, 1}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB, _X} = cmd(get, Sock,
                       fun (_H, E, _X) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(<<"aaa">>, E#mc_entry.key),
                           ?assertMatch(<<"AAA">>, E#mc_entry.data)
                       end, undefined,
                       [<<"aaa">>, <<"aaa">>, <<"bbb">>]),
        ?assertMatch(RB, <<"END\r\n">>),
        ?assertMatch([{nvals, 2}], ets:lookup(D, nvals))
    end)(),
    ok = gen_tcp:close(Sock).

delete_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    get_test_match(Sock, <<"aaa">>, <<"AAA">>),
    (fun () ->
        D = ets:new(test, [set]),
        ets:insert(D, {nvals, 0}),
        {ok, RB, _X} = cmd(delete, Sock,
                       fun (H, _E, undefined) ->
                           ets:update_counter(D, nvals, 1),
                           ?assertMatch(?DELETE, H#mc_header.opcode)
                       end, undefined,
                       #mc_entry{key = <<"aaa">>}),
        ?assertMatch(RB, <<"DELETED\r\n">>),
        ?assertMatch([{nvals, 1}], ets:lookup(D, nvals))
    end)(),
    (fun () ->
        {ok, RB, undefined} = cmd(get, Sock,
                       fun (_H, _E, undefined) -> ?assert(false) % Should not get here.
                       end, undefined,
                       [<<"aaa">>, <<"bbb">>]),
        ?assertMatch(RB, <<"END\r\n">>)
    end)(),
    ok = gen_tcp:close(Sock).

