-module(mpegtsmon_stream_uol).
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

-define(MIN_PIDS, 3).

-include("stream.hrl").

-record(state, {socket, status=#status{}, buffer_limit, id, min_bps}).

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

start_link(Args) ->
    gen_server:start_link(?MODULE, [Args], []).

mcast_of(Pid) ->
    gen_server:call(Pid,mcast_info)
.

stream_of(Pid) ->
    {mcast_of(Pid), gen_server:call(Pid,pid_info), gen_server:call(Pid,status)}
.

%% @doc The permission to fill the buffer
data_fill(Pid) ->
  gen_server:cast(Pid, data_fill)
.

%% @doc The assignment of thumb's generator
thumb_for(Pid, Thumb_pid) ->
  gen_server:cast(Pid, {thumb, Thumb_pid})
.

count_in_recording() ->
  lists:foldl(
    fun({_Id, Child, _Type, _Modules}, Acc)->
      case recording_status_of(Child) of
        true -> Acc+1;
        false -> Acc
      end
    end,
    0, mpegtsmon_stream_sup:childrens())
.

id2string(Id) ->
  inet:ntoa(Id)
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([{Mcast, [Ifaddr, Buf_limit, Min_bps]}]) ->
  io:format("~p ~p ~p ~p~n",[Ifaddr, Mcast, Buf_limit, Min_bps]),
  start_collect(),
  State = #state{
    socket=open_socket(Mcast, Ifaddr),
    status=#status{},
    buffer_limit = Buf_limit,
    id = Mcast,
    min_bps = Min_bps
  },
  mpegtsmon_stat:update(id(State), State#state.status, 0),  % for correct total number of streams on start
  {ok, State}
.

handle_call(recording_status, _From, State) ->
  {reply, mpegts_udp:record_status(State#state.socket), State}
;
handle_call(mcast_info, _From, State) ->
  {reply, State#state.id, State}
;
handle_call(pid_info, _From, State) ->
  {reply, mpegts_udp:control(State#state.socket, pids), State}
;
handle_call(status, _From, State) ->
  {reply, State#state.status , State}
;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(data_fill, State) when State#state.status#status.is_ok ->
  mpegts_udp:record_start(State#state.socket),
  {noreply, State}
;
handle_cast(data_fill, State) ->
  {noreply, State}
;
handle_cast({thumb, Thumb_pid}, State) ->
  mpegtsmon_thumb:thumb(Thumb_pid, mpegts_udp:record(State#state.socket), id(State)),
  data_request(),
  {noreply, State}
;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({mpegts_udp_record_ready, _Socket, Size}, State)->
  if State#state.status#status.is_ok ->
      data_ready();
    true -> true
  end,
  {noreply, State}
;
handle_info(first_collect, State) ->
  data_request(),
  handle_info(collect, State)
;
handle_info(collect, State) ->
  Bytes_in=mpegts_udp:control(State#state.socket, packet_count)*?TS_SIZE,
  Byte_ps = Bytes_in div ?COLLECT_INTERVAL_SEC,

  Pids_count=mpegts_udp:control(State#state.socket, pids_num),

  Scrambled = 0 < mpegts_udp:control(State#state.socket, scrambled),
  Tei = 0 < mpegts_udp:control(State#state.socket, tei),

  Bad = State#state.status#status.bad_detail#bad_detail{
    no_incoming=Byte_ps<State#state.min_bps,
    no_AV=Pids_count>0 andalso Pids_count<?MIN_PIDS,
    scrambled = Scrambled,
    tei = Tei
  },

  Status=State#state.status#status{
    byte_ps = Byte_ps,
    discontinue_pi = mpegts_udp:control(State#state.socket, errors),
    nullpid_pi = mpegts_udp:control(State#state.socket, null_pid_count),
    scrambled = Scrambled,
    external_error = Tei,
    bad_detail = Bad
  },
  Prev_ok=State#state.status#status.is_ok,
  Status_ok=Status#status{is_ok = check_ok(Status)},
  State1=State#state{status=Status_ok},

  if
    not Prev_ok andalso Status_ok#status.is_ok ->
      data_request(),
      mpegtsmon_thumb:wait(id(State));
    Prev_ok andalso not Status_ok#status.is_ok ->
      mpegts_udp:record_stop(State#state.socket),
      mpegtsmon_thumb:bad(id(State));
    true -> true
  end,

  mpegtsmon_stat:update(id(State1), Status_ok, Bytes_in),
  cont_collect(),
  {noreply, State1}
;
handle_info(_Info, State) ->
    {noreply, State}
.

terminate(_Reason, State) ->
    mpegts_udp:close(State#state.socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

open_socket({Mcast_addr, Mcast_port}, Ifaddr)->
    {ok, Socket} = mpegts_udp:open(Mcast_port, [{multicast_ttl,3},{ip,Mcast_addr},{ifip,Ifaddr}]),
    io:format("ms: ~p~n",[Socket]),
    mpegts_udp:active_once(Socket),
    Socket
.

start_collect() ->
  erlang:send_after(?COLLECT_INTERVAL div 2, self(),first_collect)
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
    Status#status.scrambled -> false;
    true -> true
  end
.

id(State) ->
  {Mcast, _Port} = State#state.id,
  Mcast
.

data_request() ->
  mpegtsmon_thumb_disp:data_request(self())
.

data_ready() ->
  mpegtsmon_thumb_disp:data_ready(self())
.

recording_status_of(Pid) ->
  gen_server:call(Pid, recording_status)
.