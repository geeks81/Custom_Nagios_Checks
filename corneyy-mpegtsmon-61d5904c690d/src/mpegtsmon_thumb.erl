-module(mpegtsmon_thumb).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([thumb/3, thumbr/3, bad/1, wait/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Size) ->
    gen_server:start_link(?MODULE, [Size], []).

thumb(Pid, Data, Stream_id) ->
  gen_server:cast(Pid,{thumb, Data, Stream_id})
.

thumbr(Pid, Data, Stream_id) ->
  gen_server:cast(Pid,{thumb_reverse, Data, Stream_id})
.

bad(Stream_id) ->
  mpegtsmon_esi:thumb(bad, mpegtsmon_stream:id2string(Stream_id))
.

wait(Stream_id) ->
  mpegtsmon_esi:thumb(wait, mpegtsmon_stream:id2string(Stream_id))
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Size]) ->
  process_flag(trap_exit, true),
  {ok, {open(Size), Size}}
.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({thumb, Data, Stream_id}, {Port, Size}) ->
  port_command(Port, Data),

  case loop(Port, <<>>) of
    <<>> -> false;
    Thumb ->
      mpegtsmon_esi:thumb(Thumb, mpegtsmon_stream:id2string(Stream_id))
  end,

  {noreply, {open(Size), Size}}
;
handle_cast({thumb_reverse, Data, Stream_id}, {Port, Size}) ->
  port_command(Port, lists:reverse(Data)),

  case loop(Port, <<>>) of
    <<>> -> false;
    Thumb ->
      mpegtsmon_esi:thumb(Thumb, mpegtsmon_stream:id2string(Stream_id))
  end,

  {noreply, {open(Size), Size}}
;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}
.

terminate(_Reason, {Port, _Size}) ->
    io:format("term~n"),
    close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

open(Size)->
  Exec = "./thumb.sh",
  Port = open_port({spawn_executable, Exec},
    [binary, stream,
      eof,
      use_stdio,
      {parallelism, true},
      {args, [integer_to_list(Size)]}
  ]),
  mpegtsmon_thumb_disp:thumb_ready(self()),
  Port
.

close(Port)->
  Port ! {self(), close}
.

loop(Port, DataL)->
  receive
    {Port, {data, Data} }->
      loop(Port, <<DataL/binary, Data/binary>>);
    {Port, {exit_status,Status}} ->
      io:format("code: ~p~n",[Status]),
      DataL;
    {Port, eof} ->
      close(Port),
      DataL;
    {'EXIT', Port, _Reason} ->
      DataL
  after 10000 ->
    io:format("code: to!~n"),
    close(Port),
    <<>>
  end
.