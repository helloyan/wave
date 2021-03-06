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

-module(wave_mod_inotify).
-author("Guillaume Bour <guillaume@bour.cc>").
-behaviour(wave_module).
-behaviour(gen_server).


% wave_module API
-export([start/1, stop/0]).
% gen_server API
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
% public functions
-export([notify/7]).

start(Opts) ->
    case start_link(Opts) of
        {ok, _}         -> ok;
        {error, Reason} -> {error, Reason};
        Err             -> {error, Err}
    end.

% do nothing for now
stop() ->
    ok.

start_link(Conf) ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [Conf], []).

init([Conf]) ->
    lager:info("starting ~p module ~p", [?MODULE, Conf]),

    mqtt_topic_registry:subscribe(<<"$/mqtt/CONNECT">>, 0, {?MODULE, notify, self(), undefined}),
    {ok, undefined}.

%%
%% PUBLIC API
%%

notify(_Pid, _, _DeviceID, {<<"$/mqtt/CONNECT">>,_}, P, _Qos, _Retain) ->
    lager:debug("notify connect"),
    {P2} = jiffy:decode(P),
    Dev = proplists:get_value(<<"deviceid">>, P2),
    Ret = proplists:get_value(<<"retcode">> , P2),

    display(<<Dev/binary, " connects (retcode=", Ret/integer,")">>),
    ok.

%notify(Pid, Topic, Payload, Qos) ->
%    P = Payload, %jiffy:decode(Payload, [return_maps]),
%    lager:info("trigger ~p", [P]),
%    ok.


display(Msg) ->
    Img = filename:join([filename:dirname(code:which(wave_app)), "..", "wave.jpg"]),
    Cmd = ["notify-send", " -i \"", Img, "\" \"", "Wave", "\" \"", erlang:binary_to_list(Msg), "\" --expire-time=2000"],
    os:cmd(lists:flatten(Cmd)),
        
    ok.



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

