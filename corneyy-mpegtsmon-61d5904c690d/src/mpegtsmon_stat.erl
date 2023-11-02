-module(mpegtsmon_stat).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(COLLECT_INTERVAL, 10000).

-include("stream.hrl").
-include("MPEGTSMON-MIB.hrl").

-record(totals, {bytes_in=0, discontinue_num=0}).

%% snmp instrumentation functions exports
-export([recv_bytes/1, continuity_errors/1, streams_total/1, streams_bad/1,
  streams_scrambled/1, streams_tei/1,
  streams_table/3]).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([update/3, list/0, streams/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% snmp instrumentation functions
recv_bytes(get) ->
  Totals = gen_server:call(?MODULE, totals),
  {value, Totals#totals.bytes_in}
.

continuity_errors(get) ->
  Totals = gen_server:call(?MODULE, totals),
  {value, Totals#totals.discontinue_num}
.

streams_total(get) ->
  {value, gen_server:call(?MODULE, streams_total)}
.

streams_bad(get) ->
  {value, gen_server:call(?MODULE, {fold,
    fun_add(fun(Status) -> not Status#status.is_ok end), 0})}
.

streams_scrambled(get) ->
  {value, gen_server:call(?MODULE, {fold,
    fun_add(fun(Status) -> Status#status.scrambled end), 0})}
.

streams_tei(get) ->
  {value, gen_server:call(?MODULE, {fold,
    fun_add(fun(Status) -> Status#status.external_error end), 0})}
.

streams_table(get, RowIndex, Cols) ->
  [get_stream_col(RowIndex, Col) || Col <- Cols]
;
streams_table(get_next, RowIndex, Cols) ->
  Streams = lists:keysort(1, gen_server:call(?MODULE, list)),
  [get_next(RowIndex, Col, Streams) || Col <- Cols]
.

get_stream_col(Row, Col) ->
  Stream_id=list_to_tuple(Row),
  case gen_server:call(?MODULE, {get, Stream_id}) of
    {ok, Stream_data} -> {value, (get_extractor_for(Col))({Stream_id, Stream_data})};
    error -> {noValue, noSuchInstance}
  end
.

get_next(_Row, Col, _Streams) when Col>=7 ->
  endOfTable
;
get_next(Row, 0, Streams) ->
  get_next(Row, 1, Streams)
;
get_next(Row, Col, Streams) ->
  case get_after(Row, Streams) of
    no_rows -> get_next([], Col+1, Streams);
    {Id, _Data}=Stream -> {[Col | tuple_to_list(Id)], (get_extractor_for(Col))(Stream)}
  end
.

get_after(_Row, []) ->
  no_rows
;
get_after([], Streams) ->
  [Stream | _Tail] = Streams,
  Stream
;
get_after(Row, Streams) ->
  Id=list_to_tuple(Row),
  [{Id_in, _Data} | Tail] = Streams,
  if
    Id_in==Id -> get_after([], Tail);
    true -> get_after(Row, Tail)
  end
.

get_extractor_for(6) ->
  fun({Id, _}) ->
    gen_server:call(?MODULE, {get_name, Id})
  end
;
get_extractor_for(5) ->
  fun({_Id, {#status{ bad_detail = Details}, _Totals}}) ->
    <<Int>> = <<0:3,
      (bool2int(Details#bad_detail.tei)):1,
      (bool2int(Details#bad_detail.scrambled)):1,
      (bool2int(Details#bad_detail.no_AV)):1,
      (bool2int(Details#bad_detail.no_incoming)):1,
      (bool2int(Details#bad_detail.no_sync)):1>>,
    Int
  end
;
get_extractor_for(4) ->
  fun({_Id, {#status{is_ok = IsOk}, _Totals}}) -> if IsOk -> ?sStatus_ok; true -> ?sStatus_bad end end
;
get_extractor_for(3) ->
  fun({_Id, {_Status, #totals{discontinue_num = Discontinue_num} }}) -> Discontinue_num end
;
get_extractor_for(2) ->
  fun({_Id, {_Status, #totals{bytes_in = Bytes_in} }}) -> Bytes_in end
;
get_extractor_for(Col) when Col==0; Col==1 ->
  fun({Id, _Data}) -> tuple_to_list(Id) end
.

bool2int(false) -> 0;
bool2int(true) -> 1.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

update(Id, Status, Bytes_in) ->
  gen_server:cast(?MODULE, {update, Id, Status, Bytes_in})
.

list() ->
  gen_server:call(?MODULE, list)
.

streams(List) ->
  gen_server:cast(?MODULE, {streams, List})
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
  process_flag(trap_exit, true),
  {ok, {dict:new(), #totals{}}}
.

handle_call({get_name, StreamId}, _From, State) ->
  {reply,binary_to_list(dict:fetch(StreamId, get(streams))), State}
;
handle_call({get, StreamId}, _From, {Streams, _Totals} = State) ->
  {reply, dict:find(StreamId, Streams), State}
;
handle_call(list, _From, {Streams, _Totals} = State) ->
  {reply, dict:to_list(Streams), State}
;
handle_call({fold, Fun, Acc}, _From, {Streams, _Totals} = State) ->
  {reply, dict:fold(Fun, Acc, Streams), State}
;
handle_call(streams_total, _From, {Streams, _Totals} = State) ->
  {reply, dict:size(Streams), State}
;
handle_call(totals, _From, {_Streams, Totals} = State) ->
  {reply, Totals, State}
;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({streams, List}, State) ->
  Dict = lists:foldl(
    fun ({Mcast_addr, {_Mcast_port, Params}}, Dict) ->
      dict:store(Mcast_addr, proplists:get_value(name, Params, <<>>), Dict)
    end, dict:new(), List),
  put(streams, Dict),
  {noreply, State}
;
handle_cast({update, Stream_id, Stream_status, Bytes_in}, {Streams, Totals}) ->
  Totals1=#totals{
    bytes_in = wrap(Totals#totals.bytes_in + Bytes_in, ?high_recvBytes),
    discontinue_num = wrap(Totals#totals.discontinue_num + Stream_status#status.discontinue_pi, ?high_continuityErrors)
  },
  Streams1 = dict:update(Stream_id, fun_update(Stream_id, {Stream_status, Bytes_in}), {#status{}, #totals{}}, Streams),
  {noreply, {Streams1, Totals1}}
;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}
.

terminate(_Reason, _State) ->
    io:format("term~n"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

fun_add(Fun) ->
  fun(_Id, {Status, _Total}, Acc) ->
    case Fun(Status) of
      true -> Acc+1;
      _Else -> Acc
    end
  end
.

wrap(Val, Max) ->
  if
    Val>Max -> Val-Max;
    true -> Val
  end
.

fun_update(Stream_id, {New_status, Bytes_in}) ->
  fun({Old_status, Old_total}) ->
    if
      not Old_status#status.is_ok andalso New_status#status.is_ok ->
        notify(Stream_id, up);
      Old_status#status.is_ok andalso not New_status#status.is_ok ->
        notify(Stream_id, down);
      true -> true
    end,
    {New_status,
    Old_total#totals{
      bytes_in = wrap(Old_total#totals.bytes_in+Bytes_in, ?high_sRecvBytes),
      discontinue_num = wrap(Old_total#totals.discontinue_num+New_status#status.discontinue_pi, ?high_sContinuityErrors)
      }
    }
  end
.

notify(Stream_id, up) ->
  notify(Stream_id, streamUp)
;
notify(Stream_id, down) ->
  notify(Stream_id, streamDown)
;
notify(Stream_id, Trap) ->
  snmpa:send_notification(snmp_master_agent, Trap, no_receiver,
    [{lastChangedStreamAddr, mpegtsmon_stream:id2string(Stream_id)}])
.