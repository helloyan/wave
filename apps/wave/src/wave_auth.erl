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

-module(wave_auth).
-author("Guillaume Bour <guillaume@bour.cc>").

-export([check/4]).

-spec check({ok, true|false}|undefined, DeviceID::binary(), Creds::{binary(), binary()},
            Setts::list({binary(), binary()})) -> {error, wrong_id|bad_credentials} | {ok, noauth|match}.
check({ok, false}, _,_,_) ->
    lager:debug("no auth required"),
    {ok, noauth};

check(_,DeviceID,_,[]) ->
    lager:debug("unknown ~p DeviceID", [DeviceID]),
    {error, wrong_id};

check(_, DeviceID, Credentials, Settings) ->
    lager:debug("auth check ~p (~p)", [DeviceID, Credentials]),

    credential(Credentials, {
        proplists:get_value(<<"username">>, Settings),
        proplists:get_value(<<"password">>, Settings)
    }).

credential(Credentials, Credentials) ->
    {ok, match};
credential(_,_) ->
    {error, bad_credentials}.

