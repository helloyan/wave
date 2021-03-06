%%
%%    Wave - MQTT Broker
%%    Copyright (C) 2014-2016 - Guillaume Bour
%%
%%    This program is free software: you can redistribute it and/or modify
%%    it under the terms of the GNU Affero General Public License as published
%%    by the Free Software Foundation, version 3 of the License.
%%
%%    This program is distributed in the hope that it will be useful,
%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%    GNU Affero General Public License for more details.
%%
%%    You should have received a copy of the GNU Affero General Public License
%%    along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(mqtt_msg).
-author("Guillaume Bour <guillaume@bour.cc>").

-export([encode/1, decode/1]).

-include("mqtt_msg.hrl").

%
% messages length:
%
% exactly 3 bytes (type + flags + rle, rle = 0):
%  - PINREQ
%  - PINRESP
%  - DISCONNECT
%
% exactly 5 bytes (type + flags + rle = 2 + varheader):
%  - CONNACK
%  - PUBACK
%  - PUBREC
%  - PUBREL
%  - PUBCOMP
%  - UNSUBACK
%
% more than 3 bytes (type + flags + rle + varheader + payload):
%  - CONNECT     (min 13 bytes)
%  - PUBLISH     (min 3)
%  - SUBSCRIBE   (min 3)
%  - SUBACK      (min 3)
%  - UNSUBSCRIBE (min 3)
%
-spec decode(binary()) -> {ok, mqtt_msg(), binary()} 
                          | {error, size, integer()}
                          | {error, overflow|{type, integer()}}
                          | {error, disconnect|conformity|protocol_version, binary()}.
decode(<<Type:4, Flags:4, Rest/binary>>) ->
    decode(type2atom(Type), <<Flags:4>>, decode_rlength(Rest, erlang:byte_size(Rest), minlen(Type))).

% invalid MQTT type
decode({invalid, T}, _, _) ->
    {error, {type, T}};
% invalid Remaining Length header or not enough buffer to decode RLen
decode(_, _, {error, overflow}) ->
    {error, overflow};
% buffer is too short to decode remaining-length header
decode(_Type, _, {error, size, Size}) ->
    lager:warning("~p: not enough data to decode rlen. missing ~p bytes", [_Type, Size]),
    {error, size, Size};
% Buffer is too short (do not contains the whole MQTT message)
decode(_, _, {ESize, RSize, _}) when ESize > RSize ->
    {error, size, ESize-RSize};

decode(Type, Flags= <<Dup:1, Qos:2, Retain:1>>, {RLen, _, Rest}) ->
    checkflags(Type, Flags), % throw exception on error

    <<BPayload:RLen/binary, Rest2/binary>> = Rest,

    Msg = case decode_payload(Type, {Dup, Qos, Retain}, {RLen, BPayload}) of
        {ok, Payload} ->
            {ok, #mqtt_msg{
                type=Type,
                retain=Retain,
                qos=Qos,
                dup=Dup,

                payload = Payload
            }, Rest2};

        {error, Err} ->
            {error, Err, Rest2}
    end,

    %lager:debug("~p", [Msg]),
    Msg.


%%
%% @doc «CONNECT» message
%% support both MQTT 3.1 and 3.1.1 versions
%%
-spec decode_payload(mqtt_verb(), {integer(), integer(), integer()}, {integer(), binary()}) ->
    {error, disconnect|conformity|protocol_version}
    | {ok, list({atom(), any()})}.
decode_payload('CONNECT', _, {_Len, <<
        PLen:16,
        Protocol:PLen/binary,
        Version:8/integer,
        Flags:7,
        Reserved:1,
        Ka:16,
        Rest/binary>>}) ->
    decode_connect(Protocol, Version, Reserved, {<<Flags:7/integer>>, Ka, Rest});


decode_payload('PUBLISH', {_Dup=1, _Qos=0, _}, _) ->
    erlang:throw({'PUBLISH', "3.3.1-2", "DUP flag MUST be 0 when QOS = 0"});
decode_payload('PUBLISH', {_     , _Qos=3, _}, _) ->
    erlang:throw({'PUBLISH', "3.3.1-4", "invalid QOS value (3)"});

decode_payload('PUBLISH', {_, Qos, _}, {_Len, Rest}) ->
    %lager:debug("PUBLISH (qos=~p) ~p ~p", [Qos, Len, Rest]),

    {Topic, Rest2} = decode_string(Rest),
    checktopic(Topic), % raise exception
    Ret = if
        Qos =:= 0 ->
            [{topic,Topic}, {data, Rest2}];
        true      ->
            <<MsgID:16, Rest3/binary>> = Rest2,
            case MsgID of
                0 -> erlang:throw({'PUBLISH', "2.3.1-1", "null msgid"});
                _ -> pass
            end,

            [{topic,Topic}, {msgid,MsgID}, {data, Rest3}]
    end,
    %{Topic, <<MsgID:16, Rest2/binary>>} = decode_string(Rest),
    %lager:debug("ret= ~p", [Ret]),

    {ok, Ret};

decode_payload('SUBSCRIBE', _, {_Len, <<MsgID:16, Payload/binary>>}) ->
    %lager:debug("SUBSCRIBE v3.1 ~p", [MsgID]),
    case MsgID of
        0 -> erlang:throw({'SUBSCRIBE', "2.3.1-1", "null msgid"});
        _ -> pass
    end,

	Topics = get_topics(Payload, [], true),
	%lager:debug("topics= ~p", [Topics]),
	{ok, [{msgid, MsgID},{topics, Topics}]};

decode_payload('UNSUBSCRIBE', _, {_Len, <<MsgID:16, Payload/binary>>}) ->
    %lager:debug("UNSUBSCRIBE: ~p", [Payload]),
    case MsgID of
        0 -> erlang:throw({'UNSUBSCRIBE', "2.3.1-1", "null msgid"});
        _ -> pass
    end,

    Topics = get_topics(Payload, [], false),
    {ok, [{msgid, MsgID}, {topics, Topics}]};

decode_payload('PINGREQ', _, {0, <<>>}) ->
    {ok, []};
decode_payload('PINGRESP', _, {0, <<>>}) ->
    {ok, []};

decode_payload('DISCONNECT', _, {0, <<>>}) ->
    %lager:debug("DISCONNECT"),
    % not a real error, we just want to close the connection
    %TODO: return a disconnect object; and do cleanup upward
    %{error, disconnect};
    {ok, []};

decode_payload('CONNACK', _, {_Len, <<_:8, RetCode:8/integer>>}) ->
    %lager:debug("CONNACK"),
    {ok, [{retcode, RetCode}]};

decode_payload('PUBACK', _, {_Len=2, <<MsgID:16>>}) ->
    %lager:debug("PUBACK. MsgID= ~p", [MsgID]),
    {ok, [{msgid, MsgID}]};

decode_payload('PUBREC', _, {_Len, <<MsgID:16>>}) ->
    %lager:debug("PUBREC. MsgID= ~p", [MsgID]),
    {ok, [{msgid, MsgID}]};

% TODO: throw exception with custom message when 'PUBREL' and qos != 1
decode_payload('PUBREL', {_, _Qos=1, _}, {_Len, <<MsgID:16>>}) ->
    %lager:debug("PUBREL. MsgID= ~p", [MsgID]),
    {ok, [{msgid, MsgID}]};

decode_payload('PUBCOMP', _, {_Len, <<MsgID:16>>}) ->
    %lager:debug("PUBREL. MsgID= ~p", [MsgID]),
    {ok, [{msgid, MsgID}]};

decode_payload('SUBACK', _, {_Len, <<MsgID:16, _Qos/binary>>}) ->
    %lager:debug("SUBACK. MsgID= ~p", [MsgID]),
    {ok, [{msgid, MsgID}]};

decode_payload(Cmd, Flags, Args) ->
    lager:notice("invalid command ~p (flags=~p, payload=~p)", [Cmd, Flags, Args]),

    {error, disconnect}.


%%%

% match wrong protocol versions
% VALID
-spec decode_connect(binary(), byte(), 0|1, {bitstring(), char(), binary()}) -> 
        {error, conformity|protocol_version} | {ok, list({atom(), any()})}.
decode_connect(<<"MQIsdp">>, Vers=3, 0, Payload) ->
    decode_connect2(Vers, Payload);
decode_connect(<<"MQTT">>  , Vers=4, 0, Payload) ->
    decode_connect2(Vers, Payload);
% ERRORS
decode_connect(_, _, _Reserved=1, _) ->
    lager:notice("CONNECT: reserved flag MUST be 0"),
    {error, conformity};
decode_connect(Protocol= <<"MQIsdp">>, Version, _, _) ->
    lager:notice("CONNECT: invalid protocol version (~p/~p)", [Protocol, Version]),
    {error, protocol_version};
decode_connect(Protocol= <<"MQTT">>, Version, _, _) ->
    lager:notice("CONNECT: invalid protocol version (~p/~p)", [Protocol, Version]),
    {error, protocol_version};
decode_connect(Protocol, _, _, _) ->
    lager:notice("CONNECT: invalid protocol name (~p)", [Protocol]),
    {error, conformity}.

-spec decode_connect2(byte(), {bitstring(), char(), binary()}) -> {error, conformity} | {ok, [{atom(), any}]}.
decode_connect2(_Version, {<<0:1, 1:1, _:5>>, _, _}) ->
    lager:notice("CONNECT: password flag is set while username flag is not"),
    {error, conformity};
decode_connect2(_, {<<_:3, WillQos:2, _:2>>, _, _}) when WillQos =:= 3 ->
    erlang:throw({'CONNECT', "MQTT-3.1.2-14", "invalid will qos (3)"});
decode_connect2(_, {<<_:3, WillQos:2, WillFlag:1, _:1>>, _, _}) when WillFlag =:= 0, WillQos =/= 0 ->
    erlang:throw({'CONNECT', "MQTT-3.1.2-13", "if will flag is 0, will qos MUST be 0 too"});
decode_connect2(_, {<<_:2, WillRetain:1, _:2, WillFlag:1, _:1>>, _, _}) when WillFlag =:= 0, WillRetain =:= 1 ->
    erlang:throw({'CONNECT', "MQTT-3.1.2-15", "if will flag is 0, will retain MUST be 0 too"});
decode_connect2(Version,
        {<<User:1, Pwd:1, WillRetain:1, WillQos:2, WillFlag:1, Clean:1>>, Ka, Rest}) ->

    % decoding Client-ID
    {ClientID, Rest2} = decode_string(Rest),
    %NOTE: disabled for now as it would require to refactor all tests
    %TODO: spec says ClientID MAY be > 23 chars and other characters
    %      add config option to change behaviour
    %check_clientid(ClientID, 0),

    % decoding will topic & message
    {Will, Rest3} = case WillFlag of
        1 ->
            {_WillTopic, _R}  = decode_string(Rest2),
            checktopic(_WillTopic), % ensure topic is valid, raise exception either (w/ WRONG msg)

            % Will message is any binary content. 2 first bytes are will message length
            %TODO: this throws an "anonymous" exception if MsgLen is missing
            %      Effect is to "kill" ranch listener, and session is ended when timeout reached
            %
            %      we should catch it (subfun) to throw a named exception
            %TODO: test is ranch listener destruction do not disconnect other clients
            <<MsgLen:16/integer, _WillMsg:MsgLen/binary, _R2/binary>> = _R,
            {#{topic => _WillTopic, message => _WillMsg, qos => WillQos, retain => WillRetain}, _R2};

        _ -> {undefined, Rest2}
    end,

    % decoding username
    {Username , Rest4} = case User of
        1 -> decode_string(Rest3);
        _ -> {undefined, Rest3}
    end,

    % decoding password
    {Password, _Rest5} = case Pwd of
        1 -> decode_string(Rest4);
        _ -> {undefined, Rest4}
    end,

    {ok, [
        {clientid , ClientID},
        {will     , Will},
        {username , Username},
        {password , Password},
        {keepalive, Ka},
        {clean    , Clean},
        {version  , Version}
    ]}.


-spec get_topics(Data :: binary(), Acc :: list(any()), Subscription :: true|false) -> 
        Topics::list(Topic::binary()|{Topic::binary(), Qos::integer()}).
get_topics(<<>>, [], true) ->
    erlang:throw({'SUBSCRIBE'  , "MQTT-3.8.3-1" , "no topic filter/qos"});
get_topics(<<>>, [], false) ->
    erlang:throw({'UNSUBSCRIBE', "MQTT-3.10.3-2", "no topic filter/qos"});
get_topics(<<>>, Topics, _) ->
    lists:reverse(Topics);
% with QOS field (SUBSCRIBE)
get_topics(Payload, Topics, true) ->
    {Name, Rest} = decode_string(Payload),
    checktopicfilter(Name),
    {Qos, Rest2} = decode_subscribe_qos(Rest),

    get_topics(Rest2, [{Name,Qos}|Topics], true);
% without QOS field (UNSUBSCRIBE)
get_topics(Payload, Topics, _) ->
    {Name, Rest} = decode_string(Payload),
    checktopicfilter(Name),
    get_topics(Rest, [Name|Topics], false).

% decode utf8 string
-spec decode_string(Data :: binary()) -> {String :: binary(), Rest :: binary()}.
decode_string(<<>>) ->
    {<<>>, <<>>};
decode_string(Pkt) ->
    %lager:debug("~p",[Pkt]),
    <<Len:16/integer, Str:Len/binary, Rest2/binary>> = Pkt,
    %lager:debug("~p ~p ~p",[Len,Pkt, Rest2]),

    case wave_utf8:validate(Str) of
        ok ->
            {Str, Rest2};

        Err ->
            erlang:throw(Err)
    end.

decode_subscribe_qos(<<_:6, Qos:2/integer, _/binary>>) when Qos =:= 3 ->
    erlang:throw({'SUBSCRIBE', "MQTT-3.8.3-4", "invalid qos (3)"});
decode_subscribe_qos(<<_:6, Qos:2/integer, Rest/binary>>) ->
    {Qos, Rest}.


-spec decode_rlength(binary(), integer(), integer()) -> {error, overflow} 
                                                        | {error, size, integer()}
                                                        | {Size::integer(), RestSize::integer(), Rest::binary()}.
decode_rlength(_Pkt, PktSize, MinLen) when PktSize < MinLen ->
    {error, size, MinLen-PktSize};
decode_rlength(Pkt, _, _) ->
    p_decode_rlength(Pkt, 1, 0).

p_decode_rlength(_, 5, _) ->
    % remaining length overflow
    {error, overflow};
p_decode_rlength(<<0:1, Len:7/integer, Rest/binary>>, Mult, Acc) ->
    {Acc + Mult*Len, erlang:byte_size(Rest), Rest};
p_decode_rlength(<<1:1, Len:7/integer, Rest/binary>>, Mult, Acc) ->
    p_decode_rlength(Rest, Mult*128, Acc + Mult*Len).


-spec encode_rlength(binary()) -> binary().
encode_rlength(Payload) ->
    encode_rlength(erlang:byte_size(Payload), <<"">>).

% shortcut for 1 byte only rlength (< 128)
-spec encode_rlength(integer(), binary()) -> binary().
encode_rlength(Size, <<"">>) when Size < 128 ->
    <<Size:8>>;
encode_rlength(0, RLen)     ->
    RLen;
encode_rlength(Size, RLen) ->
    RLen2 = Size bsr 7, % division by 128
    Digit = (Size rem 128) + ( if
        RLen2 > 0 -> 128;
        true      -> 0
    end ),

    encode_rlength(RLen2, <<RLen/binary, Digit:8>>).


-spec encode(mqtt_msg()) -> binary().
encode(#mqtt_msg{retain=Retain, qos=Qos, dup=Dup, type=Type, payload=Payload}) ->
    P = encode_payload(Type, Qos, Payload),
    %lager:info("~p ~p", [P, is_binary(P)]),

	<<
        % fixed headers
        (atom2type(Type)):4, Dup:1, Qos:2, Retain:1,
        % remaining length
        (encode_rlength(P))/binary,
        % variable headers + payload
        P/binary
    >>.

-spec encode_payload(mqtt_verb(), integer(), list({atom(), any()})) -> binary().
encode_payload('CONNECT', _Qos, Opts) ->
    ClientID = proplists:get_value(clientid, Opts),
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts),

    <<
      6:16,       % protocol name
      <<"MQIsdp">>/binary,
      3:8,        % version
      % connect flags
      (setflag(Username)):1,
      (setflag(Password)):1,
      0:6,

      10:16,      % keep-alive

      (encode_string(ClientID))/binary,
      (encode_string(Username))/binary,
      (encode_string(Password))/binary
    >>;


encode_payload('PUBLISH', _Qos=0, Opts) ->
    Topic = proplists:get_value(topic, Opts),
    Content = proplists:get_value(content, Opts),

    <<
        (encode_string(Topic))/binary,
        % payload
        (bin(Content))/binary
    >>;

encode_payload('PUBLISH', _Qos, Opts) ->
    Topic = proplists:get_value(topic, Opts),
    MsgID = proplists:get_value(msgid, Opts),
    Content = proplists:get_value(content, Opts),

    <<
        (encode_string(Topic))/binary,
        MsgID:16,
        % payload
        (bin(Content))/binary
    >>;

encode_payload('SUBSCRIBE', _Qos, Opts) ->
    Topic = proplists:get_value(topic, Opts),
    %lager:info("topic= ~p", [Topic]),

    <<
        1:16, % MsgID - mandatory
        (encode_string(Topic))/binary,
        0:8 % QoS
    >>;

encode_payload('CONNACK', _Qos, Opts) ->
    SessionPresent = proplists:get_value(session, Opts, 0),
    RetCode = proplists:get_value(retcode, Opts),

    <<
      % var headers
      0:7,
      SessionPresent:1,
      % payload
      RetCode:8
    >>;

encode_payload('PUBACK', _Qos, Opts) ->
    MsgID = proplists:get_value(msgid, Opts),

    <<
        MsgID:16
    >>;

encode_payload('PUBREC', _Qos, Opts) ->
    MsgID = proplists:get_value(msgid, Opts),

    <<
        MsgID:16
    >>;

encode_payload('PUBREL', _Qos, Opts) ->
    MsgID = proplists:get_value(msgid, Opts),

    <<
        MsgID:16
    >>;

encode_payload('PUBCOMP', _Qos, Opts) ->
    MsgID = proplists:get_value(msgid, Opts),

    <<
        MsgID:16
    >>;

encode_payload('SUBACK', _Qos, Opts) ->
    MsgId = proplists:get_value(msgid, Opts),
    Qos   = proplists:get_value(qos, Opts),

    <<
      MsgId:16,
      (encode_qos(Qos))/binary
    >>;

encode_payload('UNSUBACK', _Qos, [{msgid, MsgID}]) ->
	<<MsgID:16>>;

encode_payload('PINGREQ', _Qos, _) ->
    <<>>;
encode_payload('PINGRESP', _Qos, _) ->
	<<>>.

-spec encode_string(undefined|string()) -> binary().
encode_string(undefined) ->
    <<>>;
encode_string(Str) ->
    <<
      (size(Str)):16,
      Str/binary
    >>.

-spec encode_qos(undefined|list(integer())) -> binary().
encode_qos(undefined) ->
	<<>>;
encode_qos([]) ->
	<<>>;
encode_qos([H|T]) ->
	<<H:8/integer, (encode_qos(T))/binary>>.


-spec atom2type(mqtt_verb()) -> integer().
atom2type('CONNECT')     ->  1;
atom2type('CONNACK')     ->  2;
atom2type('PUBLISH')     ->  3;
atom2type('PUBACK')      ->  4;
atom2type('PUBREC')      ->  5;
atom2type('PUBREL')      ->  6;
atom2type('PUBCOMP')     ->  7;
atom2type('SUBSCRIBE')   ->  8;
atom2type('SUBACK')      ->  9;
atom2type('UNSUBSCRIBE') -> 10; % dialyzer generates a warning because this message is nowhere generated
atom2type('UNSUBACK')    -> 11;
atom2type('PINGREQ')     -> 12;
atom2type('PINGRESP')    -> 13;
atom2type('DISCONNECT')  -> 14. % dialyzer generates a warning because this message is nowhere generated

-spec type2atom(integer()) -> mqtt_verb() | {invalid, integer()}.
type2atom(1)  -> 'CONNECT';
type2atom(2)  -> 'CONNACK';
type2atom(3)  -> 'PUBLISH';
type2atom(4)  -> 'PUBACK';
type2atom(5)  -> 'PUBREC';
type2atom(6)  -> 'PUBREL';
type2atom(7)  -> 'PUBCOMP';
type2atom(8)  -> 'SUBSCRIBE';
type2atom(9)  -> 'SUBACK';
type2atom(10) -> 'UNSUBSCRIBE';
type2atom(11) -> 'UNSUBACK';
type2atom(12) -> 'PINGREQ';
type2atom(13) -> 'PINGRESP';
type2atom(14) -> 'DISCONNECT';
type2atom(T)  -> {invalid, T}.

% Validate flags according to MQTT verb
% [MQTT-2.2.2-1], [MQTT-2.2.2-2].
%
-spec checkflags(mqtt_verb(), <<_:4>>) -> ok.
checkflags('CONNECT'    , <<0:4>>) -> ok;
checkflags('CONNACK'    , <<0:4>>) -> ok;
checkflags('PUBLISH'    , <<_:4>>) -> ok;
checkflags('PUBACK'     , <<0:4>>) -> ok;
checkflags('PUBREC'     , <<0:4>>) -> ok;
checkflags('PUBREL'     , <<2:4>>) -> ok;
checkflags('PUBCOMP'    , <<0:4>>) -> ok;
checkflags('SUBSCRIBE'  , <<2:4>>) -> ok;
checkflags('SUBACK'     , <<0:4>>) -> ok;
checkflags('UNSUBSCRIBE', <<2:4>>) -> ok;
checkflags('UNSUBACK'   , <<0:4>>) -> ok;
checkflags('PINGREQ'    , <<0:4>>) -> ok;
checkflags('PINRESP'    , <<0:4>>) -> ok;
checkflags('DISCONNECT' , <<0:4>>) -> ok;
checkflags(Verb         , Flags) -> erlang:throw({Verb, reserved_flags, Flags}).

% Check topic name does not contains wildcard characters (+ or #)
% [MQTT-3.3.2-2], [MQTT-4.7.3-1]
%
-spec checktopic(unicode:unicode_binary()) -> ok.
checktopic(<<>>) ->
    erlang:throw({'PUBLISH', "MQTT-4.7.3-1", "0-length topic"});
checktopic(Topic) ->
    checktopic2(Topic).

checktopic2(<<>>) ->
    ok;
checktopic2(<<H/utf8, _Rest/binary>>) when H =:= $+; H =:= $# ->
    erlang:throw({'PUBLISH', "MQTT-3.3.2-2", H});
checktopic2(<<_/utf8, Rest/binary>>) ->
    checktopic2(Rest).

% Validate a topic filter
% [MQTT-4.7.1-2], [MQTT-4.7.1-3], [MQTT-4.7.3-1]
%
-spec checktopicfilter(unicode:unicode_binary()) -> ok.
checktopicfilter(<<>>) ->
    erlang:throw({'(UN)SUBSCRIBE', "[MQTT-4.7.3-1]", "0-length topic filter"});
checktopicfilter(TopicF) ->
    checktopicfilter2(TopicF).

checktopicfilter2(<<>>) ->
    ok;
checktopicfilter2(<<H/utf8, $#>>) when H =/= $/ ->
    erlang:throw({'(UN)SUBSCRIBE', "[MQTT-4.7.1-2]", "misplaced # wildcard character"});
checktopicfilter2(<<$#, _/utf8, _/binary>>) ->
    erlang:throw({'(UN)SUBSCRIBE', "[MQTT-4.7.1-2]", "misplaced # wildcard character"});
checktopicfilter2(<<H/utf8, $+, _/binary>>) when H =/= $/ ->
    erlang:throw({'(UN)SUBSCRIBE', "[MQTT-4.7.1-3]", "misplaced + wildcard character"});
checktopicfilter2(<<$+, H/utf8, _/binary>>) when H =/= $/ ->
    erlang:throw({'(UN)SUBSCRIBE', "[MQTT-4.7.1-3]", "misplaced + wildcard character"});
checktopicfilter2(<<_/utf8, Rest/binary>>)  ->
    checktopicfilter2(Rest).

% Validate clientid
% [MQTT-3.1.3-5]
%
-spec check_clientid(unicode:unicode_binary(), integer()) -> ok.
check_clientid(_, Len) when Len > 23 ->
    erlang:throw({'CONNECT', "[MQTT-3.1.3-5]", "clientid > 23 characters"});
check_clientid(<<>>, _) ->
    ok;
check_clientid(<<H/utf8, Rest/binary>>, Len) when H >= $0, H =< $9 ->
    check_clientid(Rest, Len+1);
check_clientid(<<H/utf8, Rest/binary>>, Len) when H >= $a, H =< $z ->
    check_clientid(Rest, Len+1);
check_clientid(<<H/utf8, Rest/binary>>, Len) when H >= $A, H =< $Z ->
    check_clientid(Rest, Len+1);
check_clientid(_, _) ->
    erlang:throw({'CONNECT', "[MQTT-3.1.3-5]", "clientid contains non-valid characters"}).


minlen(1)  -> 3;
minlen(2)  -> 3;
minlen(3)  -> 3;
minlen(4)  -> 3;
minlen(5)  -> 3;
minlen(6)  -> 3;
minlen(7)  -> 3;
minlen(8)  -> 3;
minlen(9)  -> 3;
minlen(10) -> 3;
minlen(11) -> 3;
minlen(12) -> 1;
minlen(13) -> 1;
minlen(14) -> 1;
minlen(_)  -> -1.


setflag(undefined) -> 0;
setflag(_)         -> 1.

%TODO: why ???
bin(X) when is_binary(X) ->
    X.
