-module(mpegtsmon).

-behaviour(application).

-define(BUF_SIZE, 2097704).


%% Application callbacks
-export([start/0, start/2, stop/1]).

%% configuration
-export([thumb_generators/0, thumb_preloads/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
  application:start(snmp),
  snmpa:load_mibs(snmp_master_agent, ["./priv/mibs/MPEGTSMON-MIB"]),
  application:start(?MODULE)
.

start(_StartType, StartArgs ) ->
  io:format("~p~n",[StartArgs]),
  Ret = mpegtsmon_sup:start_link(),

  repeat(thumb_generators(),
    fun() -> mpegtsmon_thumb_sup:start_thumb(?BUF_SIZE) end),

  List = start_streams("mcasts.txt", {ifaces_map(), [?BUF_SIZE, min_bps()]}),
  mpegtsmon_jsonrpc:start_httpd(List),
  mpegtsmon_stat:streams(List),
  mtsm_probes:start_probes("probes.txt", probes(), List),
  Ret
.

stop(_State) ->
  ok.

%% ------------------------------------------------------------------
%% Configuration
%% ------------------------------------------------------------------

thumb_generators() -> application:get_env(?MODULE, thumb_generators, 0).
thumb_preloads() ->   application:get_env(?MODULE, thumb_preloads, 0).
min_bps() ->          application:get_env(?MODULE, min_byte_per_second, 1000).
interfaces() ->       application:get_env(?MODULE, interfaces, [{default, "0.0.0.0"}]).
probes() ->           application:get_env(?MODULE, probes, [{default_port, 1235}, {alive_interval, 30}, {alive_timeout, 3}]).

%% ------------------------------------------------------------------
%% Internal function Definitions
%% ------------------------------------------------------------------

start_streams(Fname, Config)->
  {ok, File} = file:open(Fname, [read]),
  List = start_stream(File, Config, []),
  file:close(File),
  List
.

start_stream(File, Config={Ifaces_map, Stream_config}, List) ->
  case io:get_line(File, "") of
    eof  ->
      List;
    Line ->
      List2 = case process(string:tokens(Line,";\n"), List, []) of
        {{Mcast, Iface}, List1} ->
          mpegtsmon_stream_sup:start_stream({Mcast, [ifip(Iface, Ifaces_map) | Stream_config]}),
          List1;
          skip -> List
      end,
      start_stream(File, Config, List2)
  end
.

process([], _List, _Params) ->
  io:format("Skip empty~n"),
  skip
;
process([Mcast, Name, Props], List, _Params) ->
  Sparse_params = lists:foldl(
    fun(Prop, Params)->
      case string:chr(Prop, $#) of
        1 -> [{tag, list_to_binary(string:sub_string(Prop, 2))} | Params];
        0 -> [{prio, list_to_binary(Prop)} | Params]
      end
    end, [], string:tokens(Props,", ")),
  Params = proplists:delete(tag, [{tags, remove_duplicates(proplists:append_values(tag, Sparse_params))} | Sparse_params]),
  io:format("Props: ~p",[Params]),
  process([Mcast, Name], List, Params)
;
process([Mcast, Name], List, Params) ->
  io:format(" Name: ~s",[Name]),
  process([Mcast], List, [{name, list_to_binary(string:strip(Name))}|Params])
;
process([Mcast], List, Params) ->
  [Iface, Addr, Port] = parse_mcast(Mcast),
  io:format("~p:~p @~p ~n",[Addr, Port, Iface]),
  {ok, Mcast_addr}=inet:parse_address(Addr),
  {Mcast_port, _Rest} = string:to_integer(Port),
  {{{Mcast_addr, Mcast_port}, Iface}, [{Mcast_addr, {Mcast_port, Params}} | List]}
.

repeat(0, _Fun) ->
  true
;
repeat(Count, Fun)->
  Fun(),
  repeat(Count-1, Fun)
.

ifip(Addr_or_name, Map) ->
  case dict:is_key(Addr_or_name, Map) of
    true ->
      dict:fetch(Addr_or_name, Map);
    false ->
      case inet:parse_address(Addr_or_name) of
        {ok, Addr} -> Addr;
        _ -> io:format("!!! Incorrect Iface name or addr ~p~n", [Addr_or_name]),
          {0,0,0,0}
      end
  end
.

ifaces_map() ->
  {ok, List} = inet:getifaddrs(),
  Name_addr_list = lists:map(fun({Name, Options}) ->{Name, proplists:get_value(addr, Options)}  end, List),
  Ifaces_map=dict:from_list(Name_addr_list),
  Conf_list = lists:map(fun({Atom, Addr_or_str}) ->{atom_to_list(Atom),ifip(Addr_or_str,Ifaces_map)} end, interfaces()),
  dict:merge(fun(_K, V1, _V2)-> V1 end, Ifaces_map, dict:from_list(Conf_list))
.

parse_mcast(Mcast_column) ->
  case string:tokens(Mcast_column,":@ ") of
    [Mcast, Port] -> ["default", Mcast, Port];
    [S0, S1, S2] ->
      case string:str(Mcast_column,"@") of
        0 -> [S0, S1, S2];            % Iface:Maddr:Port -> [Iface, Maddr, Port]
        _ -> [S2, S0, S1]             % Maddr:Port@Iface -> [Iface, Maddr, Port]
      end
  end
.

remove_duplicates(List) ->
  sets:to_list(sets:from_list(List))
.