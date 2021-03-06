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

-module(wave_db).
-author("Guillaume Bour <guillaume@bour.cc>").

-export([get/1, set/2, set/3, del/1]).
-export([incr/1, decr/1]).
-export([append/2, push/2, pop/1, range/1, del/2, search/1, exists/1, count/1]).

-type return() :: {ok, Value::eredis:return_value()} | {error, Reason::binary()}.

%% @doc
%% Function: get/1
%% Purpose: get Value from database
%% Returns:
%%
-spec get({s, binary()} | {h, iodata()} | {h, iodata(), iodata()}) -> return().
get({s, Key}) ->
    sharded_eredis:q(["GET", Key]);
%TODO: add options to choose returned format: raw|proplist|map
get({h, Key}) ->
    case sharded_eredis:q(["HGETALL", Key]) of
        {ok, Res} -> {ok, to_proplist(Res, [])};
        Err       -> Err
    end;
%% get hash field value
get({h, Key, Field}) ->
    sharded_eredis:q(["HGET", Key, Field]).

%% @doc
%% Function: set/2
%% Purpose: insert key/value in database
%%
%% Type:
%%  - 's'   : simple key/value
%%  - 'h'   : dictionary
%%
-spec set({Type :: s|h, Key :: atom()|string()|binary()} |
          {h, atom()|string()|binary(), atom()|string()|binary()},
          Value :: any()) -> return().
set({s, Key}, Value) ->
    sharded_eredis:q(["SET", Key, Value]);
set({h, Key}, Value) when is_list(Value) ->
    sharded_eredis:q(["HMSET", Key | Value]);
set({h, Key}, Value) when is_map(Value) ->
    % #{A => B}  => [A, B].
    Params = lists:flatmap(fun({X,Y}) -> [X,Y] end, maps:to_list(Value)),
    set({h, Key}, Params);
set({h, Key, Field}, Value) ->
    sharded_eredis:q(["HSET", Key, Field, Value]).

%% @doc
%%
%%
-spec set({s|h, binary()}, any(), list()) -> return().
set(Key, Value, []) ->
    set(Key, Value);
set(Key={_,K}, Value, [{expiration,Expiration}|Opts]) -> 
    lager:debug("set db expiration: ~p", [Expiration]),

    case set(Key, Value, Opts) of
        {ok, X} ->
            case sharded_eredis:q(["EXPIRE", K, Expiration]) of
                {ok, _} -> {ok, X};
                Err2    -> Err2
            end;

        Err -> Err
    end;
set({s, Key}, Value, [nx]) ->
    sharded_eredis:q(["SETNX", Key, Value]).

-spec del(binary()) -> return().
del(Key) ->
    sharded_eredis:q(["DEL", Key]).

-spec del(binary(), integer()) -> return().
del(Key, Start) ->
    sharded_eredis:q(["LTRIM", Key, Start, -1]).

%% @doc
%% Function: search/2
%% Purpose: search keys in database
-spec search(iodata()) -> return().
search(Pattern) ->
    sharded_eredis:q(["KEYS", Pattern]).

-spec exists(iodata()) -> return().
exists(Key) ->
    sharded_eredis:q(["EXISTS", Key]).

%%
%% Counters operations
%%
-spec incr(binary()) -> return().
incr(Key) ->
    sharded_eredis:q(["INCR", Key]).

-spec decr(binary()) -> return().
decr(Key) ->
    sharded_eredis:q(["DECR", Key]).


%%
%% Lists specific operations
%%
-spec append(binary(), any()) -> return().
append(List, Value) ->
    sharded_eredis:q(["LPUSH", List, Value]).

-spec push(iodata(), any()) -> return().
push(List, Value) when is_list(Value) ->
    sharded_eredis:q(["RPUSH", List|Value]);
push(List, Value) ->
    sharded_eredis:q(["RPUSH", List, Value]).

-spec pop(atom()|binary()) -> return().
pop(List) ->
    sharded_eredis:q(["LPOP", List]).

-spec range(binary()) -> return().
range(List) ->
    sharded_eredis:q(["LRANGE", List, 0, -1]).

-spec count(binary()) -> integer() | return().
count(Key) ->
    %NOTE: 'KEYS' is locking
    case  sharded_eredis:q(["EVAL", <<"return #redis.pcall('KEYS', '",Key/binary,"')">>, 0]) of
        {ok, Res} ->
            {ok, wave_utils:int(Res)};
        Err -> Err
    end.


%%
%%
%%
to_proplist([], Acc) ->
    Acc;
to_proplist([K, V | Rest], Acc) ->
    to_proplist(Rest, [{K,V} | Acc]).

