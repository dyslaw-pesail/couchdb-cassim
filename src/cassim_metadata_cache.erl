% Copyright 2014 Cloudant
%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(cassim_metadata_cache).
-behaviour(gen_server).


-export([
    start_link/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    load_meta/1,
    load_meta/2,
    load_meta/3,
    metadata_db/0,
    metadata_db_exists/0
]).


-record(st, {
    changes_pid,
    last_seq="0",
    global_db
}).


-include_lib("couch/include/couch_db.hrl").


-define(META_TABLE, metadata_cache).
-define(TABLE_OPTS, [set, protected, named_table]).


metadata_db() ->
    config:get("couchdb", "metadata_db", "cassim").


metadata_db_exists() ->
    try mem3:shards(metadata_db()) of
        _Shards ->
            true
    catch error:database_does_not_exist ->
        false
    end.


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ets:new(?META_TABLE, ?TABLE_OPTS),
    GlobalDb = metadata_db(),
    {Pid, _} = spawn_monitor(fun() -> listen_for_changes("0") end),
    {ok, #st{changes_pid = Pid, global_db=GlobalDb}}.


handle_call(get_seq, _From, State) ->
    {reply, State#st.last_seq, State};
handle_call({fetch_meta, MetaId}, _From, State) ->
    {reply, load_meta_from_db(State#st.global_db, MetaId), State};
handle_call({fetch_meta, Db, MetaId}, _From, State) ->
    {reply, load_meta_from_db(Db, MetaId), State};
handle_call(Call, _From, State) ->
    couch_log:error("Unknown cassim_metadata_cache call: ~p~n", [Call]),
    {noreply, State}.


handle_cast({insert_cached_meta, {MetaId, Props}}, State) ->
    ets:insert(?META_TABLE, {MetaId, Props}),
    {noreply, State};
handle_cast({delete_meta, MetaId}, State) ->
    ets:delete(?META_TABLE, MetaId),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info({'DOWN', _, _, Pid, Reason}, #st{changes_pid=Pid} = State) ->
    {Delay, Seq} = case Reason of
        {seq, EndSeq} ->
            {5 * 1000, EndSeq};
        {error, database_does_not_exist} ->
            couch_log:error("Metadata db ~p does not exist", [metadata_db()]),
            {5 * 60 * 1000, State#st.last_seq};
        _ ->
            couch_log:notice("~p changes listener died ~p", [?MODULE, Reason]),
            {5 * 1000, State#st.last_seq}
    end,
    timer:send_after(Delay, {start_listener, Seq}),
    {noreply, State#st{last_seq=Seq, changes_pid=undefined}};
handle_info({start_listener, Seq}, #st{changes_pid=undefined} = State) ->
    {NewPid, _} = spawn_monitor(fun() -> listen_for_changes(Seq) end),
    {noreply, State#st{changes_pid=NewPid}};
handle_info(_Msg, State) ->
    {noreply, State}.


terminate(_Reason, #st{changes_pid = Pid}) ->
    exit(Pid, kill),
    ok.


code_change(_OldVsn, #st{}=State, _Extra) ->
    {ok, State}.


%% internal functions


listen_for_changes(Since) ->
    DbName = metadata_db(),
    Args = #changes_args{
        feed = "continuous",
        since = Since,
        heartbeat = true,
        include_docs = true
    },
    fabric:changes(DbName, fun changes_callback/2, Since, Args).


changes_callback(start, Since) ->
    {ok, Since};
changes_callback({stop, EndSeq}, _) ->
    exit({seq, EndSeq});
changes_callback({change, {Change}}, _) ->
    Id = couch_util:get_value(id, Change),
    case couch_util:get_value(deleted, Change, false) of
        true ->
            gen_server:cast(?MODULE, {delete_meta, Id});
        false ->
            case couch_util:get_value(doc, Change) of
                {error, Reason} ->
                    couch_log:warn(
                        "could not retrieve metadata doc ~s: ~p", [Id, Reason]);
                Props ->
                    gen_server:cast(?MODULE, {insert_cached_meta, {Id, Props}})
            end
    end,
    {ok, couch_util:get_value(seq, Change)};
changes_callback(timeout, EndSeq) ->
    exit({seq, EndSeq});
changes_callback({error, database_does_not_exist}, _EndSeq) ->
    exit({error, database_does_not_exist});
changes_callback({error, _}, EndSeq) ->
    exit({seq, EndSeq}).


%% internal metadata functions


load_meta_from_db(DbName, MetaId) ->
    try fabric:open_doc(DbName, MetaId, []) of
        {ok, Doc} ->
            couch_doc:to_json_obj(Doc, []);
        _Else ->
            couch_log:warn("no record of meta ~s", [MetaId]),
            undefined
    catch error:database_does_not_exist ->
        undefined
    end.


load_meta(MetaId) ->
    load_meta(MetaId, true).


load_meta(MetaId, _UseCache=true) ->
    case fetch_cached_meta(MetaId) of
        undefined ->
            load_meta(MetaId, false);
        Props ->
            Props
    end;
load_meta(MetaId, _UseCache=false) ->
    gen_server:call(?MODULE, {fetch_meta, MetaId}).


load_meta(MetaId, _UseCache=false, Db) ->
    gen_server:call(?MODULE, {fetch_meta, Db, MetaId}).


fetch_cached_meta(MetaId) ->
    try ets:lookup(?META_TABLE, MetaId) of
        [{MetaId, Props}] ->
            Props;
        [] ->
            couch_log:notice("cache miss on metadata ~s", [MetaId]),
            undefined
        catch error:badarg ->
            couch_log:notice("cache miss on metadata ~s", [MetaId]),
            undefined
    end.