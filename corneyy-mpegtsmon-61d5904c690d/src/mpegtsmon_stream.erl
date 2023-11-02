-module(mpegtsmon_stream).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(TS_SIZE, 188).
-define(PID_PAT, 16#0).
-define(PID_CAT, 16#1).
-define(PID_TSDT, 16#2).
-define(PID_IGNORE_MIN, 16#1).
-define(PID_IGNORE_MAX, 16#F).
-define(PID_NULL, 16#1FFF).

-define(CC_MIN, 16#0).
-define(CC_MAX, 16#F).

-define(COLLECT_INTERVAL, 10000).
-define(COLLECT_INTERVAL_SEC, (?COLLECT_INTERVAL div 1000)).

-define(MIN_BPS, 1000).
-define(MIN_PIDS, 3).

-include("stream.hrl").

-record(state, {socket, pids, status=#status{}, bytes_curr=0, cc_err_curr=0, null_curr=0,
  buffer_limit=0, buffer= [], buffer_size=0}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([mcast_of/1, stream_of/1, thumb_for/2, id2string/1, data_fill/1, count_in_recording/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Mcast) ->
    gen_server:start_link(?MODULE, [Mcast], []).

mcast_of(Pid) ->
    gen_server:call(Pid,mcast_info)
.

stream_of(Pid) ->
    {mcast_of(Pid), gen_server:call(Pid,pid_info), gen_server:call(Pid,status)}
.

data_fill(Pid) ->
  gen_server:cast(Pid, data_fill)
.

thumb_for(Pid, Thumb_pid) ->
  gen_server:cast(Pid, {thumb, Thumb_pid})
.

count_in_recording() ->
  mpegtsmon_stream_uol:count_in_recording()
.

id2string(Id) ->
  inet:ntoa(Id)
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([{Mcast, Buf_limit}]) ->
    io:format("~p ~p~n",[Mcast, Buf_limit]),
    start_collect(),
    {ok, #state{socket=open_socket(Mcast), pids=gb_trees:empty(), status=#status{}, buffer_limit = Buf_limit}}
.

handle_call(mcast_info, _From, State) ->
    case inet:sockname(State#state.socket) of
        {ok, {Address, Port}} ->
            {reply, {Address, Port}, State};
        {error, Error} ->
            {reply, {error, Error}, State}
    end
;
handle_call(pid_info, _From, State) ->
  {reply, gb_trees:keys(State#state.pids), State}
;
handle_call(status, _From, State) ->
  {reply, State#state.status , State}
;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({thumb, Thumb_pid}, State) ->
  mpegtsmon_thumb:thumbr(Thumb_pid, State#state.buffer, id(State)),
  State1=State#state{
    buffer= [],
    buffer_size=0
  },
  {noreply, State1}
;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, _Socket, _Ip, _Port, Packet}, State)->
    {noreply, process_data(Packet, State)}
;
handle_info(collect, State) ->
  Byte_ps = State#state.bytes_curr div ?COLLECT_INTERVAL_SEC,

  Pids_count=gb_trees:size(State#state.pids),

  Bad = State#state.status#status.bad_detail#bad_detail{
    no_incoming=Byte_ps<?MIN_BPS,
    no_AV=Pids_count>0 andalso Pids_count<?MIN_PIDS
  },

  Status=State#state.status#status{
    byte_ps = Byte_ps,
    discontinue_pi = State#state.cc_err_curr,
    nullpid_pi = State#state.null_curr,
    bad_detail = Bad
  },
  Status_ok=Status#status{is_ok = check_ok(Status)},
  State1=State#state{status=Status_ok, bytes_curr = 0, cc_err_curr = 0, null_curr = 0},

  if
    Status_ok#status.is_ok -> true;
    true ->
      mpegtsmon_thumb:bad(id(State))
  end,

  cont_collect(),
  {noreply, State1}
;
handle_info(_Info, State) ->
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

open_socket({Mcast_addr, Mcast_port})->
    {ok, Local_addr}=inet:parse_address("0.0.0.0"),
    {ok, Socket}=gen_udp:open(Mcast_port, [
% default        {read_packets, 5},
        {ip, Mcast_addr},
        {reuseaddr, true},
        {recbuf, 65535},
        inet,
        binary,
        {active, true},
        {add_membership, {Mcast_addr, Local_addr }}]),
    Socket
.

process_data(Data, State) ->
  if
    State#state.status#status.is_ok ->
        if
          State#state.buffer_size<State#state.buffer_limit ->
            Buffer = [Data | State#state.buffer],
            Buffer_size = State#state.buffer_size+byte_size(Data),
            if
              Buffer_size>=State#state.buffer_limit ->
                mpegtsmon_thumb_disp:data_ready(self());
              true -> true
            end
            ;
          true ->
            Buffer = State#state.buffer,
            Buffer_size = State#state.buffer_size
        end;
    true ->
      Buffer = [],
      Buffer_size = 0
  end,

  State1=State#state{
    bytes_curr = State#state.bytes_curr+byte_size(Data),
    buffer=Buffer,
    buffer_size=Buffer_size
  },

  process_frame(Data, State1)
.

process_frame(Packet, State) when byte_size(Packet) div ?TS_SIZE >0, byte_size(Packet) rem ?TS_SIZE ==0 ->
    State1=decode(binary_part(Packet,0,?TS_SIZE), State),
    case  byte_size(Packet) of
        ?TS_SIZE ->
            State1;
        _->
            process_frame(binary_part(Packet,?TS_SIZE,byte_size(Packet)-?TS_SIZE), State1)
    end
;
process_frame(_Packet, State)->
    State
.

decode(<<16#47, Tei:1, _Pusi:1, _Tp:1, Pid:13, Tsc:2, Afc0:1, Afc1:1, Cc:4, _Rest/binary>>, State)  ->
%  io:format("tei:~B PID: ~.16B afc: ~B~B cc:~B~n",[Tei, Pid, Afc0, Afc1, Cc]),
    External_error = case Tei of
        0 -> false;
        1 -> true
    end,
    Scrambled = case Tsc of
        0 -> false;
        _ -> true
    end,
    case Afc0 of
        0 -> true;
        1 ->
%            <<Af_len:8, Di:1, _Rest1/bitstring>>=Rest,
            true%      io:format("Pid: ~.16B cc:~p AF len:~p Di:~p~n",[Pid, Cc, Af_len, Di])
    end,
    Bad = State#state.status#status.bad_detail#bad_detail{no_sync=false},
    Status = State#state.status#status{external_error=External_error, scrambled = Scrambled, bad_detail = Bad},
    State1 = State#state{status=Status},
    case Afc1 of
        1 ->
            process_pid(Pid, Cc, State1); % process only packet with payload
        0 -> State1
    end
;
decode(<<_Sync, _Rest/binary>>, State)  ->
  Bad=State#state.status#status.bad_detail#bad_detail{no_sync=true},
  State#state{status=State#state.status#status{bad_detail=Bad}}
.

process_pid(?PID_NULL, _Cc, State)->
  State#state{null_curr = State#state.null_curr + 1 }
;
%process_pid(Pid, _Cc, State) when Pid >= ?PID_IGNORE_MIN, Pid =< ?PID_IGNORE_MAX ->
%    State
%;
process_pid(Pid, Cc, State) ->
%  io:format("~.16B ~p~n", [Pid, Cc]),
    case gb_trees:lookup(Pid, State#state.pids) of
        {value, Old_cc} ->
            State1=check_cc(Pid, Old_cc, Cc, State),
            State1#state{pids=gb_trees:update(Pid, Cc, State#state.pids)};
        none ->
            State#state{pids=gb_trees:insert(Pid, Cc, State#state.pids)}
    end
.

check_cc(Pid, Old_cc, New_cc, State) ->
  Correct = compare_cc(Old_cc, New_cc),
  case Correct of
    false ->
      print_ccc(Pid, Old_cc, New_cc, State#state.socket, Correct),
      State#state{cc_err_curr = State#state.cc_err_curr + 1 };
    true ->
      State
    end
.

compare_cc(Old_cc, New_cc) when Old_cc+1 == New_cc ->
    true
;
compare_cc(?CC_MAX, ?CC_MIN) ->
    true
;
compare_cc(_Old_cc, _New_cc) ->
    false
.

print_ccc(Pid, Old_cc, New_cc, Socket, false) ->
    io:format("~p ~p cc bad pid:~.16B old cc:~p new cc:~p~n", [self(), Socket, Pid, Old_cc, New_cc])
.

start_collect() ->
  erlang:send_after(?COLLECT_INTERVAL div 2, self(),collect)
.

cont_collect() ->
  erlang:send_after(?COLLECT_INTERVAL, self(),collect)
.

check_ok(Status) ->
  if
    Status#status.bad_detail#bad_detail.no_incoming -> false;
    Status#status.bad_detail#bad_detail.no_sync -> false;
    Status#status.bad_detail#bad_detail.no_AV -> false;
    Status#status.external_error -> false;
    true -> true
  end
.

id(State) ->
  case inet:sockname(State#state.socket) of
    {ok, {Address, _Port}} ->
      Address;
    {error, _Error} ->
      undefined
  end
.