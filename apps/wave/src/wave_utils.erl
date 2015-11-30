
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

-module(wave_utils).
-author("Guillaume Bour <guillaume@bour.cc>").

-export([atom/1, str/1]).

%%
%% @doc converts to atom
%%
atom(X) when is_list(X) ->
    erlang:list_to_atom(X);
atom(_) ->
    erlang:error(wrongtype).

%%
%% @doc converts to string (list)
%%
str(X) when is_atom(X) ->
    erlang:atom_to_list(X);
str(_) ->
    erlang:error(wrongtype).