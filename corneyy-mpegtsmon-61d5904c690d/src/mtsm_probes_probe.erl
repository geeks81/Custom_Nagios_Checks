-module(mtsm_probes_probe).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(ALIVE_PAUSE_SEC, 3).

-define(COLLECT_INTERVAL, 10000).
-define(COLLECT_INTERVAL_SEC, (?COLLECT_INTERVAL div 1000)).

-define(TRANSIT_INTERVAL, 5000).

-define(PROBE_STATUS_INTERVAL_SEC, 10).
-define(PROBE_STATUS_TIMEOUT_SEC, (?PROBE_STATUS_INTERVAL_SEC + 3)).

-define(STREAM_COLLECT_INTERVAL_SEC, 30).

-define(MSG_ALIVE,      1).
-define(MSG_CHECK,      2).
-define(MSG_STATUS,     3).
-define(MSG_STOP_CHECK, 4).

-include("probe.hrl").

-record(state, {id, socket, addr, port, alive_interval, alive_timeout,
  status=unknown, sq=0, last_seen=0, transit, streams_tail=[],
  streams_num=0, probe_max_streams=0, alive_id, probe_alive_id=0, probe_sq=0,
  last_update_time}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([extract_cc_pktin/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link(?MODULE, [Args], []).

extract_cc_pktin(<<_Int_addr:32/big-unsigned-integer, _Port:16/big-unsigned-integer,
    _Buffer_overflow:32/big-unsigned-integer, _Sync_error:32/big-unsigned-integer,
    Error_count:32/big-unsigned-integer, _Tei:32/big-unsigned-integer, _Scrambled:32/big-unsigned-integer,
    _Pids_num:32/big-unsigned-integer, Packet_count:32/big-unsigned-integer,
    _Null_count:32/big-unsigned-integer, _Rest/binary>>) ->
  {Error_count, Packet_count}
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([{Probe_id, Probe={Probe_addr, Probe_port, Probe_max}, Config}]) ->
    io:format("~p ~p~n",[Probe, Config]),
    random:seed(erlang:phash2(self()), erlang:phash2(Probe_addr), erlang:monotonic_time()),
    start_alive(?ALIVE_PAUSE_SEC+random:uniform(?ALIVE_PAUSE_SEC*2)),
    start_collect(),
    start_transit(),
    mtsm_probes_stat:update(Probe_id, #probe_state{}, []),
    {ok, #state{
      id=Probe_id,
      socket=open_socket(), addr=Probe_addr, port=Probe_port,
      alive_interval=proplists:get_value(alive_interval, Config),
      alive_timeout=proplists:get_value(alive_timeout, Config),
      transit=dict:new(),
      streams_num=mtsm_probes:streams_num(),
      probe_max_streams=Probe_max,
      alive_id=alive_id(),
      last_update_time=current_time()
    }}
.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, _Socket, _Ip, _Port, Packet}, State=#state{probe_sq=Prev_probe_sq}) ->
  case Packet of
    <<"MTSM", Probe_sq:64/big-unsigned-integer,
      Last_sq:64/big-unsigned-integer,
      Msg_type:8/integer, Msg/binary>> ->
      State1 = incoming(Probe_sq>Prev_probe_sq, {Probe_sq, Last_sq}, Msg_type, Msg, status(up, State#state{last_seen=current_time()})),
      {noreply, State1}
    ;
    _Other -> io:format("unkn packet ~p~n",[Packet]),
      {noreply, State}
    end
;
handle_info(transit, State) ->
  State1 = check_next_stream(State),
  start_transit(),
  {noreply, transit_pass(State1)}
;
handle_info(collect, State=#state{id=Probe_id, status=Status, last_update_time=Last_update_time}) ->
  mtsm_probes_stat:update(Probe_id, #probe_state{status=Status}, updated_status_transit(Last_update_time, State)),
  cont_collect(),
  {noreply, State#state{last_update_time=current_time()}}
;
handle_info({timeout, Old_ls}, State=#state{last_seen=Last_seen}) ->
  case Last_seen-Old_ls of
    0      -> {noreply, status(down, State)};
    _Other -> {noreply, State}
  end
;
handle_info(alive, State=#state{alive_interval=Interval, alive_timeout=Timeout,
  last_seen=Last_seen, alive_id=Alive_id}) ->
  State1 = send_msg(?MSG_ALIVE, <<Alive_id:64/big-unsigned-integer, 0:32/big-unsigned-integer>>, State),
  cont_alive(Interval),
  start_timeout(Timeout, Last_seen),
  {noreply, State1}
;
handle_info(Info, State) ->
  io:format("unhandled info ~p ~p~n",[Info, State]),
  {noreply, State}
.

terminate(_Reason, State) ->
    gen_udp:close(State#state.socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

open_socket()->
    {ok, Socket}=gen_udp:open(0, [inet, binary, {active, true}]),
    Socket
.

status(New_status, State=#state{status=Old_status}) when New_status==Old_status ->
  State
;
status(New_status, State=#state{status=Old_status}) ->
  on_status(Old_status, New_status, State#state{status=New_status})
.

on_status(_Old, down, State) ->
  %%TODO Change state of all streams to unknown
  transit_clear([check], State)
;
on_status(_Old, up, State) ->
  check_next_stream(State)
.

incoming(true, {Probe_sq, _Last_sq}, Msg_type, Msg, State) -> %%TODO misorder and dups
  incoming(Msg_type, Msg, State#state{probe_sq=Probe_sq})
;
incoming(false, {Probe_sq, _Last_sq}, ?MSG_ALIVE,
    <<Probe_alive_id:64/big-unsigned-integer, Dups:32/big-unsigned-integer, _Rest/binary>>, State) ->
  incoming_alive(Probe_alive_id, Probe_sq, Dups, State)
;
incoming(false, _Sqs, Msg_type, Msg, State) ->
  io:format(" Ignore!!! ~p ~p~n", [Msg_type, Msg]),
  State
.

incoming(?MSG_STATUS, <<Int_addr:32/big-unsigned-integer, Port:16/big-unsigned-integer,
  _Buffer_overflow:32/big-unsigned-integer, _Sync_error:32/big-unsigned-integer,
  Error_count:32/big-unsigned-integer, _Tei:32/big-unsigned-integer, _Scrambled:32/big-unsigned-integer,
  Pids_num:32/big-unsigned-integer, Packet_count:32/big-unsigned-integer,
  _Null_count:32/big-unsigned-integer, _Rest/binary>>=Status, State) ->
  transit_event(status, Int_addr, Port, State, Status)
;
incoming(?MSG_ALIVE, <<Probe_alive_id:64/big-unsigned-integer, Dups:32/big-unsigned-integer, _Rest/binary>>, State) ->
  incoming_alive(Probe_alive_id, 0, Dups, State)
;
incoming(?MSG_STOP_CHECK, <<Addr:32/big-unsigned-integer, Port:16/big-unsigned-integer, _Rest/binary>>, State) ->
  transit_event(stop, Addr, Port, State)
;
incoming(Msg_type, Msg, State) ->
  io:format(" UNK!!! ~p ~p~n",[Msg_type, Msg]),
  State
.

incoming_alive(New_probe_alive_id, _Probe_sq, _Dups, State=#state{probe_alive_id=Probe_alive_id})
  when New_probe_alive_id==Probe_alive_id ->
  State
;
incoming_alive(New_probe_alive_id, _Probe_sq, _Dups, State=#state{probe_alive_id=Probe_alive_id})
  when Probe_alive_id==0 ->
  State#state{probe_alive_id=New_probe_alive_id}
;
incoming_alive(New_probe_alive_id, Probe_sq, _Dups, State) ->
  reset(State#state{probe_alive_id=New_probe_alive_id, probe_sq=Probe_sq})
.

reset(State) ->
  transit_reset(State)
.

stop(Mcast, State) ->
  send_mcast(?MSG_STOP_CHECK, Mcast, State)
.

check(Mcast, State) ->
  send_mcast(?MSG_CHECK, Mcast, State)
.

send_mcast(Msg_type, {{A3, A2, A1 , A0}, Mcast_port}, State) ->
  send_msg(Msg_type, <<A3, A2, A1, A0, Mcast_port:16/big-unsigned-integer>>, State)
.

send_msg(Msg_type, Msg, State=#state{socket=Socket, addr=Addr, port=Port, sq=Sq, probe_sq=Probe_sq}) ->
  Sq1=1+Sq,
  gen_udp:send(Socket, Addr, Port,
    [<<"MTSM", Sq1:64/big-unsigned-integer, Probe_sq:64/big-unsigned-integer, Msg_type:8/integer>>, Msg]),
  State#state{sq=Sq1}
.

transit_pass(State=#state{transit=Transit}) ->
  Time = current_time(),
  Prepared = dict:filter(fun(_Mcast, Stat) -> transit_prepare(Stat, Time, State) end, Transit),
  dict:fold(fun(Mcast, {Stat, _Stat_time, _}, State_) -> transit_exec(Stat, Mcast, State_) end, State, Prepared)
.

transit_prepare({stop, Stop_time, _}, Curr_time, #state{alive_timeout=Stop_timeout})
  when Curr_time-Stop_time>=Stop_timeout -> % need resend stop
  true
;
transit_prepare({status, Check_time, _}, Curr_time, #state{streams_num=Streams_num, probe_max_streams=Probe_max})
  when Curr_time-Check_time>=?STREAM_COLLECT_INTERVAL_SEC andalso Probe_max<Streams_num -> % enough
  true
;
transit_prepare({check, Check_time, _}, Curr_time, _State)
  when Curr_time-Check_time>=?PROBE_STATUS_TIMEOUT_SEC -> % need resend check
  true
;
transit_prepare(_Stat, _Curr_time, _State) ->
  false
.

transit_event(status, Int_addr, Port, State=#state{transit=Transit}, Status) -> % check -> status. fix first status time
  Transit1 = dict:update({int2addr(Int_addr), Port},
    fun
      ({status, First_time, _Last}) -> {status, First_time, {current_time(), Status}};
      (Stat={stop, _Other, _}) -> Stat ;
      ({check, _Other, _}) -> {status, current_time(), {current_time(), Status}} end,
    {status, current_time(), {current_time(), Status}}, Transit),
  State#state{transit=Transit1}
.

transit_event(stop, Int_addr, Port, State=#state{transit=Transit}) -> % stop -> out from transit
  check_next_stream(State#state{transit=dict:erase({int2addr(Int_addr), Port}, Transit)})
.

transit_exec(status, Mcast, State=#state{transit=Transit}) -> % send stop
  Transit1=dict:store(Mcast, {stop, current_time(), {}}, Transit),
  stop(Mcast, State#state{transit=Transit1})
;
transit_exec(stop, Mcast, State=#state{transit=Transit}) -> % send stop
  Transit1=dict:store(Mcast, {stop, current_time(), {}}, Transit),
  stop(Mcast, State#state{transit=Transit1})
;
transit_exec(check, Mcast, State=#state{transit=Transit}) -> % send check
  Transit1=dict:store(Mcast, {check, current_time(), {}}, Transit),
  check(Mcast, State#state{transit=Transit1})
.

transit_count(Stat_list, #state{transit=Transit}) when is_list(Stat_list) ->
  dict:fold(fun
      (_Mcast, {Stat_, _Stat_time, _}, Count) ->
        case lists:member(Stat_, Stat_list) of
          true -> 1+Count;
          false -> Count
        end
        end,
    0, Transit)
.

transit_clear(Stat_list, State=#state{transit=Transit}) when is_list(Stat_list) ->
  Prepared = dict:fold(fun
     (Mcast, {Stat_, _Stat_time, _}, List) ->
       case lists:member(Stat_, Stat_list) of
         true -> [ Mcast | List];
         false -> List
       end
     end,
    [], Transit),
  State#state{transit=lists:foldl(fun dict:erase/2, Transit, Prepared)}
.

transit_reset(State) ->
  State#state{transit=dict:new()}
.

updated_status_transit(Last_update_time, #state{transit=Transit}) ->
  dict:fold(fun
              (Mcast, {status, _First_time, Stat={Last_time, _Status}}, List) when Last_time>=Last_update_time ->
                [{Mcast, Stat} | List]
              ;
              (_Mcast, _Stat, List) -> List
            end,
    [], Transit)
.

check_next_stream(State=#state{probe_max_streams=Probe_max, status=Status }) when Status==up ->
  check_next_stream(Probe_max, transit_count([check, status], State), State)
;
check_next_stream(State) ->
  State
.

check_next_stream(Target_num, Intransit_num, State=#state{streams_tail=Streams, streams_num=Streams_num})
  when Target_num>Intransit_num andalso Intransit_num<Streams_num ->
  {{Stream, _Params}, Streams1} = next_stream(Streams),
  transit_exec(check, Stream, State#state{streams_tail=Streams1})
;
check_next_stream(_Target_num, _Intransit_num, State) ->
  State
.

next_stream([]) ->
  [Stream | Streams] = mtsm_probes:streams(),
  {Stream, Streams}
;
next_stream([Stream | Streams]) ->
  {Stream, Streams}
.

start_transit() ->
  erlang:send_after(?TRANSIT_INTERVAL, self(), transit)
.

start_alive(Pause) ->
  send_after(Pause, alive)
.

cont_alive(Interval) ->
  send_after(Interval, alive)
.

start_timeout(Timeout, Args) ->
  send_after(Timeout, {timeout, Args})
.

start_collect() ->
  erlang:send_after(?COLLECT_INTERVAL div 2, self(), collect)
.

cont_collect() ->
  erlang:send_after(?COLLECT_INTERVAL, self(), collect)
.

send_after(Interval, Msg) ->
  erlang:send_after(1000*Interval, self(), Msg)
.

current_time() ->
  erlang:monotonic_time(seconds)
.

int2addr(Int) ->
  <<A3, A2, A1, A0>> = binary:encode_unsigned(Int),
  {A3, A2, A1, A0}
.

alive_id() ->
  os:system_time(milli_seconds)
.