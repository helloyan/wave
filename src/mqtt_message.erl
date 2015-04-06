%%
%%    Wave - MQTT Broker
%%    Copyright (C) 2014 - Guillaume Bour
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

-module(mqtt_message).
-author("Guillaume Bour <guillaume@bour.cc>").
-behaviour(gen_fsm).

-include("include/mqtt_msg.hrl").


% gen_fsm
-export([start_link/0]).
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
% API
-export([publish/2, delivered/2]).

% INTERNAL
-export([await/2, published/2]).

-record(state, {
    subscribers=[]
}).

%-define(CONNECT_TIMEOUT  , 5000). % ms

start_link() ->
    gen_fsm:start_link(?MODULE, undef, []).

init(_) ->
	{ok, await, #state{}}.

%% API

publish(Pid, {in, Message, ClientPid}) ->
    gen_fsm:send_event(Pid, {in, Message, ClientPid});
publish(Pid, {out, Message, ClientPid}) ->
    gen_fsm:send_event(Pid, {out, Message, ClientPid}).

delivered(Pid, Target) ->
    gen_fsm:send_event(Pid, {delivered, Target}).

%% INTERNAL EVENT STATES
%%
%% INCOMING MESSAGE - coming from peer device (TCP socket in)
await({in, #mqtt_msg{type='PUBLISH', qos=Qos, payload=P}, ClientPid}, StateData) when Qos =:= 0 ->
    Topic   = proplists:get_value(topic, P),
    Content = proplists:get_value(data, P),
    lager:debug("await: received PUBLISH"),

    MatchList = mqtt_topic_registry:match(Topic),
    lager:info("matchlist= ~p", [MatchList]),
    [
        case is_process_alive(Pid) of
            true ->
                lager:info("candidate: pid=~p, topic=~p, content=~p", [Pid, Topic, Content]),
                Mod:Fun(Pid, {Topic,TopicMatch}, undef, Content, min(Qos, PubQos), {undef,undef,undef});

            _ ->
                % SHOULD NEVER HAPPEND
                lager:error("deadbeef ~p", [Pid])

        end

        || _Subscr={TopicMatch, {Mod,Fun,Pid}, _Fields, PubQos} <- MatchList
    ],

    %{next_state, await, StateData}.
    % currently we just destroy the message server (qos = 0 => no response awaited)
    % TODO: pool in back this server to pool mngr
    {stop, normal, StateData};

% qos=1 message
await({in, #mqtt_msg{type='PUBLISH', qos=Qos, payload=P}, ClientPid}, StateData) when Qos =:= 1 ->
    Topic   = proplists:get_value(topic, P),
    Content = proplists:get_value(data, P),
    MsgId   = proplists:get_value(msgid, P),
    lager:debug("await: received PUBLISH (QoS=1)"),

    MatchList = mqtt_topic_registry:match(Topic),
    lager:info("matchlist= ~p", [MatchList]),
    [
        case is_process_alive(Pid) of
            true ->
                lager:info("candidate: pid=~p, topic=~p, content=~p", [Pid, Topic, Content]),
                Mod:Fun(Pid, {Topic,TopicMatch}, MsgId, Content, min(Qos, PubQos), {?MODULE, delivered, self()});

            _ ->
                % SHOULD NEVER HAPPEND
                lager:error("deadbeef ~p", [Pid])

        end

        || _Subscr={TopicMatch, {Mod,Fun,Pid}, _Fields, PubQos} <- MatchList
    ],

	%{next_state, await, StateData}.
    % currently we just destroy the message server (qos = 0 => no response awaited)
    % TODO: pool in back this server to pool mngr
    {next_state, published, StateData};

%% OUT MESSAGE
await({out, {Topic, _, Content, Qos=0, _Clb, {Callback,Transport,Socket}}, ClientPid}, StateData) ->
    Msg   = #mqtt_msg{type='PUBLISH', payload=[{topic,Topic}, {content, Content}]},
    Callback:send(Transport, Socket, Msg),

    % currently we destroy the server just know
    % TODO: pool in
    {stop, normal, StateData};

await({out, {Topic, MsgID, Content, Qos=1, Clb, {Callback,Transport,Socket}}, ClientPid}, StateData) ->
    Msg   = #mqtt_msg{type='PUBLISH', qos=Qos, payload=[{topic,Topic}, {msgid, MsgID}, {content, Content}]},
    Callback:send(Transport, Socket, Msg),

    % notify delivery
    {M,F,Pid} = Clb,
    M:F(Pid, {MsgID, self(), Topic}),

    % currently we destroy the server just know
    % TODO: pool in
    {stop, normal, StateData}.

published({delivered, {MsgID, Pid, Topic}}, StateData) ->
    lager:debug("#~p MsgID delivered by ~p (~p)", [MsgID, Pid, Topic]),
    {next_state, published, StateData}.


%%
%% GEN_FSM INTERNAL API
%%

handle_event(_Event, _StateName, StateData) ->
	lager:debug("event ~p", [_StateName]),
    {stop, error, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
	lager:debug("syncevent ~p", [_StateName]),
    {stop, error, error, StateData}.

handle_info(_Info, _StateName, StateData) ->
	lager:debug("info ~p", [_StateName]),
    {stop, error, StateData}.

terminate(_Reason, _StateName, _StateData) ->
    lager:info("session terminate: ~p (~p ~p)", [_Reason, _StateName, _StateData]),
    terminate.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

