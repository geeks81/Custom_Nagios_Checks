-module(mpegtsmon_thumb_disp).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(CHECK_INTERVAL, 60000).

-record(state, {thumbs, streams, preloads, preloads_left, waits}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([data_ready/1, thumb_ready/1, data_request/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [{preloads, mpegtsmon:thumb_preloads()}], []).

%% @doc The generator ready for processing.
thumb_ready(Pid) ->
  gen_server:cast(?MODULE,{thumb_ready, Pid})
.

%% @doc Request for ability to fill the stream's buffer.
data_request(Pid) ->
  gen_server:cast(?MODULE,{data_request, Pid})
.

%% @doc The stream's buffer ready for processing.
data_ready(Pid) ->
  gen_server:cast(?MODULE,{data_ready, Pid})
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([{preloads, Preloads}]) ->
  preload_refresh(),
  {ok, #state{thumbs=queue:new(), streams=queue:new(), preloads=Preloads, preloads_left=Preloads, waits=queue:new()}}
.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({data_request, Pid}, State) ->
  Left = State#state.preloads_left,
  if
    Left==0 ->
      case queue:is_empty(State#state.waits) of
        true ->
          {noreply, refresh_by_reality(Pid, State)};
        false ->
          {noreply, State#state{waits=queue:in(Pid, State#state.waits)}}
      end;
    Left>0 ->
      mpegtsmon_stream:data_fill(Pid),
      {noreply, State#state{preloads_left=Left-1}}
  end
;
handle_cast({thumb_ready, Pid}, State) ->
  case queue:is_empty(State#state.streams) of
     true ->
       {noreply, State#state{thumbs=queue:in(Pid,State#state.thumbs)}};
     false ->
       {{value, Stream_pid}, Streams} = queue:out(State#state.streams),
       Waits = thumb_for(Stream_pid, Pid, State#state.waits),
       {noreply, State#state{streams=Streams, waits=Waits}}
  end
;
handle_cast({data_ready, Pid}, State) ->
%  io:format("streams query len ~p waits ~p~n",[queue:len(State#state.streams), queue:len(State#state.waits)]),
  case queue:is_empty(State#state.thumbs) of
    true ->
      {noreply, State#state{streams=queue:in(Pid,State#state.streams)}};
    false ->
      {{value, Thumb_pid}, Thumbs} = queue:out(State#state.thumbs),
      Waits = thumb_for(Pid, Thumb_pid, State#state.waits),
      {noreply, State#state{thumbs=Thumbs, waits=Waits}}
  end
;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(preload_refresh, State) ->
  In_rec = mpegtsmon_stream:count_in_recording(),
%  io:format("in rec ~p~n",[In_rec]),
  Preloads = State#state.preloads,
  Ready = queue:len(State#state.streams),
  Total = In_rec + Ready,
  if
    Total < Preloads ->
%      io:format("preload ~p~n",[Preloads - Total]),
      Waits = State#state.waits,
      Waits1 = repeat(erlang:min(Preloads - Total, queue:len(Waits)),
        fun(W) -> preload_next(W) end
        , Waits),
      Ret = {noreply,State#state{waits=Waits1}};
    true ->
      Ret = {noreply, State}
  end,
  preload_refresh(),
  Ret
;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

thumb_for(Stream_pid, Thumb_pid, Waits) ->
  mpegtsmon_stream:thumb_for(Stream_pid, Thumb_pid),
  preload_next(Waits)
.

preload_next(Waits) ->
  case queue:is_empty(Waits) of
    true ->
%      io:format("thumb_disp: Waits queue is empty!~n"),
      Waits;
    false ->
      {{value, Pid}, Waits1} = queue:out(Waits),
      mpegtsmon_stream:data_fill(Pid),
      Waits1
  end
.
refresh_by_reality(Pid, State) ->
  In_rec = mpegtsmon_stream:count_in_recording(),
  Preloads = State#state.preloads,
  Ready = queue:len(State#state.streams),
  Total = In_rec + Ready,
%  io:format("reality ~p ~p~n",[In_rec, Preloads]),
  if
    Total < Preloads ->
      mpegtsmon_stream:data_fill(Pid),
      State#state{preloads_left = Preloads - Total - 1};
    true ->
      State#state{waits=queue:in(Pid, State#state.waits)}
  end
.

preload_refresh() ->
  erlang:send_after(?CHECK_INTERVAL, self(), preload_refresh)
.

repeat(0, _Fun, Arg) ->
  Arg
;
repeat(Count, Fun, Arg)->
  repeat(Count-1, Fun, Fun(Arg))
.
