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

-module(wave_acl).
-author("Guillaume Bour <guillaume@bour.cc>").
-behaviour(gen_server).

% gen_server API
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(ETS_VISIBILITY      , private).
-define(DFT_MONITOR_INTERVAL, 60000). % 1 minute

-export([]).
-ifdef(DEBUG).
    -undef(ETS_VISIBILITY).
    -define(ETS_VISIBILITY, public).

    -undef(DFT_MONITOR_INTERVAL).
    -define(DFT_MONITOR_INTERVAL, 2000).

    -export([switch/1]).
-endif.

-record(state, {
    filename,
    last_modified = undefined
}).

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(Args) ->
    ets:new(?MODULE, [bag, named_table, ?ETS_VISIBILITY]),
    % 1st monitor will trigger file load
    erlang:send_after(50, self(), monitor),
    {ok, #state{filename=proplists:get_value(file, Args)}}.

%%
%% PUBLIC API
%%

-ifdef(DEBUG).
switch(File) ->
    gen_server:call(?MODULE, {switch, File}).
-endif.

%%
%% PRIVATE API
%%

% load a new acl file
handle_call({switch, File}, _, State) ->
    reload(File),
    {reply, ok, State#state{filename=File, last_modified=filelib:last_modified(File)}};

handle_call(E,_,State) ->
    lager:error("call ~p", [E]),
    {reply, ok, State}.


handle_cast(E, State) ->
    lager:error("cast ~p", [E]),
    {noreply, State}.


% monitor acl file changes
handle_info(monitor, State=#state{filename=File, last_modified=LastMod}) ->
    LastMod2 = filelib:last_modified(File),
    if LastMod2 =/= LastMod -> reload(File); true -> ok end,

    erlang:send_after(?DFT_MONITOR_INTERVAL, self(), monitor),
    {noreply, State#state{last_modified=LastMod2}};

% force reloading file
handle_info(reload, State=#state{filename=File}) ->
    reload(File),
    {noreply, State#state{last_modified=filelib:last_modified(File)}};

handle_info(E, State) ->
    lager:error("info ~p", [E]),
    {noreply, State}.


terminate(_,_) ->
    ok.


code_change(_, State, _) ->
    {ok, State}.

%%
%% PRIVATE FUNS
%%

reload(File) ->
    % TODO: handle errors
    case file:open(File, [read,binary]) of
        {ok, F} ->
            % this is a security (avoiding blocking users if smth goes wrong with password file)
            ets:delete_all_objects(?MODULE),

            Count = fill_ets(F, file:read_line(F), 0),
            file:close(F),

            lager:debug("acl file reloaded (~p lines found)", [Count]);

        Err ->
            lager:error("failed to (re)load acl file ~p: ~p", [File, Err])
    end.

fill_ets(_, eof, Count) ->
    Count;
fill_ets(F, {ok, Line}, Count) ->
    S = size(Line)-1, % Line includes trailing \n
    <<Line2:S/binary, $\n>> = Line ,

    case binary:split(Line2, <<$\t>>, [global]) of
        [User, <<"allow">>, Mode= <<"read">>, Topic]  -> ets:insert(?MODULE, {anon(User), read, Topic});
        [User, <<"allow">>, Mode= <<"write">>, Topic] -> ets:insert(?MODULE, {anon(User), write, Topic});

        [User, <<"allow">>, <<"readwrite">>, Topic]  ->
            User2 = anon(User),

            ets:insert(?MODULE, {User2, read, Topic}),
            ets:insert(?MODULE, {User2, write, Topic});

        Err ->
            lager:warning("invalid acl entry at line ~B: ~p", [Count, Line2])
    end,

    fill_ets(F, file:read_line(F), Count+1).

anon(<<"anonymous">>) -> undefined;
anon(User)            -> User.

