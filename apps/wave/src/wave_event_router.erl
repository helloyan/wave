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

-module(wave_event_router).
-author("Guillaume Bour <guillaume@bour.cc>").
-behaviour(gen_server).


%
-export([route/2]).
% gen_server API
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Conf) ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [Conf], []).

init([Conf]) ->
    lager:info("starting ~p module ~p", [?MODULE, Conf]),

    {ok, undefined}.


%%
%% PUBLIC API
%%


route(Topic, Msg) ->
    MatchList = mqtt_topic_registry:match(Topic),
    lager:debug("routing ~p, match ~p", [Topic, MatchList]),

    route2(MatchList, Topic, Msg).

route2([], _, _) ->
    ok;

%
% NOTE:
%  - internal module (inotify) is expecting an erlang native fmt (ie proplists or maps)
%  - mqtt worker (client proxy) is awaiting binary only
%
%  NOW: we use binary fmt only
%  IN THE FUTURE: each topic subscriber specify awaited format at registration, and we adapt
%
% i.e
%   mqtt_session:initiate(CONNECT) -> emit "$/mqtt/CONNECT" with [{deviceid, X},{retcode, Y}]
%

%
% encoding proplists
route2(MatchList, Topic, Msg) when is_list(Msg) ->
    JSon = jiffy:encode({Msg}),
    route3(MatchList, Topic, JSon).

%
% propagating message to subscribers
route3([], _, _) ->
    ok;
route3([Subscr|T], Topic, Content) ->
    {TopicMatch, SQos, {Mod,Fun,Pid}, _Fields} = Subscr,

    case is_process_alive(Pid) of
        true ->
            lager:info("candidate: pid=~p, topic=~p, content=~p", [Pid, Topic, Content]),
            % use self() or undef as sender Pid ?
            Ret = Mod:Fun(Pid, self(), {Topic,TopicMatch}, Content, SQos),
            lager:info("publish to client: ~p", [Ret]),
            case {SQos, Ret} of
                {0, disconnect} ->
                    lager:debug("client ~p disconnected but QoS = 0. message dropped", [Pid]);

                {_, disconnect} ->
                    lager:debug("client ~p disconnected while sending message", [Pid]),
%                        mqtt_topic_registry:unsubscribe(Subscr),
%                        mqtt_offline:register(Topic, DeviceID),
                    mqtt_offline:event(undefined, {Topic, SQos}, Content),
                    ok;

                _ ->
                    ok
            end;

        _ ->
            % SHOULD NEVER HAPPEND
            lager:error("deadbeef ~p", [Pid])
    end,

    route3(T, Topic, Content).


%%
%% PRIVATE API
%%

handle_call(_,_,State) ->
    {reply, ok, State}.


handle_cast(_, State) ->
    {noreply, State}.


handle_info(_, State) ->
    {noreply, State}.


terminate(_,_) ->
    ok.


code_change(_, State, _) ->
    {ok, State}.
