%%% @author     Max Lapshin & Co
%%% @copyright  2012 Max Lapshin, 2015 Co
%%% @doc        UDP Mpeg-TS off-load
%%% @reference  http://farbow.ru/mpegtsmon/en
%%% @end
%%%
%%%---------------------------------------------------------------------------------------
-module(mpegts_udp).
-author('Max Lapshin & Co').

-define(CMD_OPEN, 1).
-define(CMD_ERRORS, 2).
-define(CMD_SCRAMBLED, 3).
-define(CMD_PACKET_COUNT, 4).
-define(CMD_ACTIVE_ONCE, 5).
-define(CMD_PIDS_NUM, 6).
-define(CMD_NULL_COUNT, 7).
-define(CMD_PIDS, 8).
-define(CMD_RECORD_START, 9).
-define(CMD_RECORD, 10).
-define(CMD_RECORD_STOP, 11).
-define(CMD_RECORD_STATUS, 12).
-define(CMD_TEI, 13).

-export([open/2, close/1, active_once/1]).
-export([record_start/1, record/1, record_stop/1, record_status/1]).
-export([control/2]).


record(Socket)->
  port_control(Socket, ?CMD_RECORD, <<>>)
.

record_start(Socket)->
  port_control(Socket, ?CMD_RECORD_START, <<>>)
.

record_stop(Socket)->
  port_control(Socket, ?CMD_RECORD_STOP, <<>>)
.

record_status(Socket)->
  <<Status:8>> = port_control(Socket, ?CMD_RECORD_STATUS, <<>>),
  Status>0
.

control(Socket, tei) ->
  <<TEICount:32/little>> = port_control(Socket, ?CMD_TEI, <<>>),
  TEICount
;
control(Socket, pids) ->
  erlang:port_call(Socket, ?CMD_PIDS,[])
;
control(Socket, null_pid_count) ->
  <<NullCount:32/little>> = port_control(Socket, ?CMD_NULL_COUNT, <<>>),
  NullCount
;
control(Socket, pids_num) ->
  <<PidsNum:32/little>> = port_control(Socket, ?CMD_PIDS_NUM, <<>>),
  PidsNum
;
control(Socket, errors) ->
  <<Errors:32/little>> = port_control(Socket, ?CMD_ERRORS, <<>>),
  Errors
;
control(Socket, packet_count) ->
  <<PacketCount:32/little>> = port_control(Socket, ?CMD_PACKET_COUNT, <<>>),
  PacketCount
;
control(Socket, scrambled) ->
  <<ScrambledCount:32/little>> = port_control(Socket, ?CMD_SCRAMBLED, <<>>),
  ScrambledCount
.



open(Port, Options) ->
  Path = case code:lib_dir(priv) of
    {error, _} -> "priv";
    LibDir -> LibDir
  end,
  Loaded = case erl_ddll:load_driver(Path, mpegts_udp) of
  	ok -> ok;
  	{error, already_loaded} -> ok;
  	{error, Error} -> {error, {could_not_load_driver,erl_ddll:format_error(Error)}}
  end,
  io:format("~p~n",[Loaded]),
  case Loaded of
    ok ->
      Socket = open_port({spawn, mpegts_udp}, [binary]),
      Multicast = case proplists:get_value(multicast_ttl, Options) of
        undefined -> <<>>;
        _ -> get_ip(ip, Options, <<>>) end,
      Iface = get_ip(ifip, Options, <<0,0,0,0>>),
      <<"ok">> = port_control(Socket, ?CMD_OPEN, <<Port:16, Multicast/binary, Iface/binary>>),
      erlang:port_set_data(Socket, inet_udp),
      {ok, Socket};
    Else ->
      Else
  end.


active_once(Port) ->
  <<"ok">> = port_control(Port, ?CMD_ACTIVE_ONCE, <<>>),
  ok.


close(Socket) ->
  erlang:port_close(Socket).

get_ip(Prop, Options, Default) ->
  case proplists:get_value(Prop, Options) of
    undefined -> Default;
    MC when is_list(MC) ->
      {ok, {I1,I2,I3,I4}} = inet_parse:address(MC),
      <<I1, I2, I3, I4>>;
    {I1,I2,I3,I4} ->
      <<I1, I2, I3, I4>>
  end
.