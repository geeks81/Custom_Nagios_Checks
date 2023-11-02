-module(mtsm_probes_stat).
-behaviour(gen_server).

-define(INVALIDATION_INTERVAL, 10000).
-define(STATUS_RELEVANCE_INTERVAL_SEC, 30).

-include("probe.hrl").
-include("MPEGTSMON-MIB.hrl").

%% snmp instrumentation functions exports
-export([probes_table/3, probes_streams_table/3]).

%% API
-export([start_link/0]).
-export([update/3, state/1, streams/1, streams/0, streams_state/2,
  probes/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

update(Probe_id, Probe_state, Updated) ->
  case ets:lookup(stat_db, Probe_id) of
    [{Probe_id, Prev_probe_state}] -> on_update_probe_state(Probe_id, Prev_probe_state, Probe_state);
    [] -> true
  end,
  ets:insert(stat_db, {Probe_id, Probe_state}),
  lists:foreach(fun (Stat) -> update_mcast(Probe_id, Stat) end, Updated)
.

state(Probe_id) ->
  ets:lookup_element(stat_db, Probe_id, 2)
.

streams(Streams) ->
  ets:insert(stat_db, {streams, lists:map(fun({Addr, {Port, Params}}) -> {{Addr, Port}, Params} end, Streams)})
.

streams() ->
  case ets:lookup(stat_db, streams) of
    [{_K, S}] -> S;
    [] -> []
  end
.

streams_state(Probe_id, Convertor) ->
  lists:foldl(
    fun({Mcast={Stream_id, _}, _Params}, List) ->
      case ets:lookup(stat_db, {collected, Probe_id, Stream_id}) of
        [{_Key, State}] -> [Convertor({Mcast, State}) | List];
        [] -> List
      end
    end,
    [], ets:lookup_element(stat_db, streams, 2))
.

probes(List) ->
  gen_server:cast(?MODULE,{set_probes_list, List})
.

%% snmp instrumentation functions

probes_table(get, RowIndex, Cols) ->
  [get_probe_col(RowIndex, Col) || Col <- Cols]
;
probes_table(get_next, RowIndex, Cols) ->
  Probes = lists:keysort(1, gen_server:call(?MODULE, probes_list)),
  [get_next(RowIndex, Col, Probes) || Col <- Cols]
.

get_probe_col(Row, Col) ->
  Probe_id=list_to_tuple(Row),
  case ets:member(stat_db, Probe_id) of
    true -> {value, (get_extractor_for(Col))({Probe_id, {}})};
    false -> {noValue, noSuchInstance}
  end
.

get_next(_Row, Col, _Probes) when Col>=7 ->
  endOfTable
;
get_next(Row, 0, Probes) ->
  get_next(Row, 1, Probes)
;
get_next(Row, Col, Probes) ->
  case get_after(Row, Probes) of
    no_rows -> get_next([], Col+1, Probes);
    {Id, _Data}=Probe -> {[Col | tuple_to_list(Id)], (get_extractor_for(Col))(Probe)}
  end
.

get_after(_Row, []) ->
  no_rows
;
get_after([], Probes) ->
  [Probe | _Tail] = Probes,
  Probe
;
get_after(Row, Probes) ->
  Id=list_to_tuple(Row),
  [{Id_in, _Data} | Tail] = Probes,
  if
    Id_in==Id -> get_after([], Tail);
    true -> get_after(Row, Tail)
  end
.

get_extractor_for(6) ->
  fun({Id, _}) ->
    case (state(Id))#probe_state.status of
      up ->      ?pStatus_up;
      down ->    ?pStatus_down;
      unknown -> ?pStatus_unknown
    end
  end
;
get_extractor_for(Col) when Col>1, Col<6 ->
  fun(_) -> 0 end
;
get_extractor_for(Col) when Col==0; Col==1 ->
  fun({Id, _Data}) -> tuple_to_list(Id) end
.

probes_streams_table(get, RowIndex, Cols) ->
  [get_probe_stream_col(RowIndex, Col) || Col <- Cols]
;
probes_streams_table(get_next, RowIndex, Cols) ->
  Probes = lists:keysort(1, gen_server:call(?MODULE, probes_list)),
  Streams = lists:keysort(1, streams()),
  [ps_get_next(RowIndex, Col, Probes, Streams) || Col <- Cols]
.

get_probe_stream_col([P3, P2, P1, P0, S3, S2, S1, S0], Col) ->
  {value, (ps_get_extractor_for(Col))({P3, P2, P1, P0}, {S3, S2, S1, S0})}
;
get_probe_stream_col(_RowIndex, _Col) ->
  {noValue, noSuchInstance}
.

ps_get_next(_Row, _Col, _Probes, []) ->
  endOfTable
;
ps_get_next(_Row, Col, _Probes, _Streams) when Col>=3 ->
  endOfTable
;
ps_get_next(Row, 0, Probes, Streams) ->
  ps_get_next(Row, 1, Probes, Streams)
;
ps_get_next(Row, Col, Probes, Streams) ->
  case ps_get_after(Row, Probes, Streams) of
    no_rows -> ps_get_next([], Col+1, Probes, Streams);
    {Probe_id, Stream_id} -> {lists:append([Col | tuple_to_list(Probe_id)], tuple_to_list(Stream_id)), (ps_get_extractor_for(Col))(Probe_id, Stream_id)}
  end
.

ps_get_after(_Row, [], _Streams_tail, _Streams) ->
  no_rows
;
ps_get_after(Row, Probes, [], Streams) ->
  [_Probe| Probes_tail] = Probes,
  ps_get_after(Row, Probes_tail, Streams, Streams)
;
ps_get_after([], Probes, Streams_tail, _Streams) ->
  ps_get_after([], Probes, Streams_tail)
;
ps_get_after(Row={Probe_id, Stream_id}, Probes, Streams_tail, Streams) ->
  [{Probe_id_in, _} | Probes_tail] = Probes,
  if
    Probe_id_in==Probe_id ->
      [{{Stream_id_in, _}, _} | Streams_tail1] = Streams_tail,
      if
        Stream_id_in==Stream_id -> ps_get_after([], Probes, Streams_tail1, Streams);
        true -> ps_get_after(Row, Probes, Streams_tail1, Streams)
      end;

    true -> ps_get_after(Row, Probes_tail, Streams, Streams)
  end
.

ps_get_after([], Probes, Streams) ->
  [{Probe_Id, _} | _] = Probes,
  [{{Stream_Id, _Port}, _} | _] = Streams,
  {Probe_Id, Stream_Id}
;
ps_get_after([P3, P2, P1, P0, S3, S2, S1, S0], Probes, Streams) ->
  ps_get_after({{P3, P2, P1, P0}, {S3, S2, S1, S0}}, Probes, Streams, Streams)
.

ps_get_extractor_for(2) ->
  fun(Probe_id, Stream_id) ->
    stream_state(Probe_id, Stream_id,
      fun({_, Status, _, _}) ->
        case Status of
          up ->      ?psStatus_up;
          down ->    ?psStatus_down;
          unknown -> ?psStatus_unknown
        end
      end, ?psStatus_unknown)
  end
;
ps_get_extractor_for(1) ->
  fun(Probe_id, Stream_id) ->
    stream_state(Probe_id, Stream_id, fun({_, _, Cc, _}) -> Cc end, 0)
  end
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
  ets:new(stat_db, [named_table, public]),
  cont_invalidation(),
  {ok, {[]}}
.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(probes_list, _From, State={Probes}) ->
  {reply, Probes, State}
;
handle_call(_Request, _From, State) ->
  {reply, ok, State}
.

handle_cast({set_probes_list, List}, _State) ->
  {noreply, {List}}
;
handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in mtsm_probes_stat: ~p", [Request]),
    {noreply, State}.

handle_info(invalidation, State={Probes}) ->
  lists:foreach(
  fun({Probe_id, _}) ->lists:foreach(
    fun({{Stream_id, _}, _}) ->
      case ets:lookup(stat_db, {collected, Probe_id, Stream_id}) of
        [{Key, Stat}] -> ets:insert(stat_db, {Key, update_status(Stat, current_time())});
        [] -> true
      end
    end,
    ets:lookup_element(stat_db, streams, 2))
  end, Probes),
  cont_invalidation(),
  {noreply, State}
;
handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in mtsm_probes_stat: ~p", [Info]),
    {noreply, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

update_mcast(Probe_id, Updated={Mcast, _Stat}) ->
  update_mcast(Probe_id, Updated, ets:lookup(stat_db, {last, Probe_id, Mcast}))
.

update_mcast(Probe_id, {Mcast={Stream_id, _}, Stat}, [{_Key, Prev_stat}]) ->
  Extracted=extract(Stat),
  Collected=ets:lookup_element(stat_db, {collected, Probe_id, Stream_id}, 2),
  ets:insert(stat_db, {{collected, Probe_id, Stream_id}, New=update_status(Collected, Prev_stat, Extracted)}),
  ets:insert(stat_db, {{last, Probe_id, Mcast}, Replaced=replace_status(Extracted, New)}),
  on_update_stream_state(Probe_id, Stream_id, Prev_stat, Replaced)
;
update_mcast(Probe_id, {Mcast={Stream_id, _}, Stat}, []) ->
  Extracted=extract(Stat),
  ets:insert(stat_db, {{last, Probe_id, Mcast}, Extracted}),
  ets:insert(stat_db, {{collected, Probe_id, Stream_id}, Extracted})
.

extract({Last_time, Status}) ->
  {Cc, Pktin}=extract_cc_pktin(Status),
  {Last_time, unknown, Cc, Pktin}
.

extract_cc_pktin(Status) ->
  mtsm_probes_probe:extract_cc_pktin(Status)
.

update_status({Last_time, _Collected_status, Collected_cc, Collected_pktin}, Time) when Time-Last_time>?STATUS_RELEVANCE_INTERVAL_SEC ->
  {Last_time, unknown, Collected_cc, Collected_pktin}
;
update_status(Stat, _Time) ->
  Stat
.

update_status({_Last_time, _Collected_status, Collected_cc, Collected_pktin},
    _Prev, {Last_time, _Status, _Cc, 0})  ->
  {Last_time, down, Collected_cc, Collected_pktin}
;
update_status({_Last_time, _Collected_status, Collected_cc, Collected_pktin},
    {_Last_time, _Prev_status, _Prev_cc, Prev_pktin}, {Last_time, _Status, _Cc, Pktin}) when Pktin==Prev_pktin ->
  {Last_time, down, Collected_cc, Collected_pktin}
;
update_status({_Last_time, _Collected_status, Collected_cc, Collected_pktin},
    {_Last_time, _Prev_status, Prev_cc, Prev_pktin}, {Last_time, _Status, Cc, Pktin}) when Pktin>Prev_pktin ->
  {Last_time, up, Collected_cc+(Cc-Prev_cc), Collected_pktin+(Pktin-Prev_pktin)} %%TODO wrap
;
update_status({_Last_time, _Collected_status, Collected_cc, Collected_pktin},
    _Prev, {Last_time, _Status, Cc, Pktin}) ->
  {Last_time, up, Collected_cc+Cc, Collected_pktin+Pktin}
.

on_update_probe_state(Probe_id, #probe_state{status=up}, #probe_state{status=down}) ->
  notify(Probe_id, down)
;
on_update_probe_state(Probe_id, #probe_state{status=down}, #probe_state{status=up}) ->
  notify(Probe_id, up)
;
on_update_probe_state(_Probe_id, _Prev, _New) ->
  true
.

replace_status(In, {_Last_time, unknown, _Cc, _Pktin}) ->
  In
;
replace_status({_In_last_time, _Status, _In_cc, _In_pktin}, {_Last_time, Status, _Cc, _Pktin}) ->
  {_In_last_time, Status, _In_cc, _In_pktin}
.

on_update_stream_state(Probe_id, Stream_id, {_Prev_last_time, up, _Prev_cc, _Prev_pktin}, {_Last_time, down, _Cc, _Pktin}) ->
  stream_notify(Probe_id, Stream_id, down)
;
on_update_stream_state(Probe_id, Stream_id, {_Prev_last_time, down, _Prev_cc, _Prev_pktin}, {_Last_time, up, _Cc, _Pktin}) ->
  stream_notify(Probe_id, Stream_id, up)
;
on_update_stream_state(_Probe_id, _Stream_id, _Prev, _New) ->
  true
.

current_time() ->
  erlang:monotonic_time(seconds)
.

cont_invalidation() ->
  erlang:send_after(?INVALIDATION_INTERVAL, self(), invalidation)
.

notify(Probe_id, up) ->
  notify(Probe_id, probeUp)
;
notify(Probe_id, down) ->
  notify(Probe_id, probeDown)
;
notify(Probe_id, Trap) ->
  snmpa:send_notification(snmp_master_agent, Trap, no_receiver,
    [{pIP, tuple_to_list(Probe_id)}])
.

stream_state(Probe_id, Stream_id, Convertor, Unk) ->
  case ets:lookup(stat_db, {collected, Probe_id, Stream_id}) of
    [{_Key, State}] -> Convertor(State);
    [] -> Unk
  end
.

stream_notify(Probe_id, Steam_id, up) ->
  stream_notify(Probe_id, Steam_id, streamAtProbeUp)
;
stream_notify(Probe_id, Steam_id, down) ->
  stream_notify(Probe_id, Steam_id, streamAtProbeDown)
;
stream_notify(Probe_id, Stream_id, Trap) ->
  snmpa:send_notification(snmp_master_agent, Trap, no_receiver,
    [{pIP, tuple_to_list(Probe_id)}, {sIP, tuple_to_list(Stream_id)}])
.
