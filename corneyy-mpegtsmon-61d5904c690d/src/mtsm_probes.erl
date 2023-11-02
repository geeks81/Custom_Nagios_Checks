-module(mtsm_probes).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_probes/3]).
-export([id2string/1, streams/0, streams_num/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_probes(Fname, Config, Streams) ->
  case file:open(Fname, [read]) of
    {ok, File} ->
      io:format("Start probes\n"),
      Ret = mtsm_probes_sup:start_link(),
      mtsm_probes_stat:streams(Streams),
      Probes = start_probe(File, Config, []),
      file:close(File),
      mtsm_probes_stat:probes(Probes),
      mtsm_probes_jsonrpc:probes(Probes),
      Ret;
    _Other ->
      mtsm_probes_stat:start_link(), %% for correct SNMP response
      ignore
  end
.

id2string(Id) ->
  inet:ntoa(Id)
.

streams() ->
  mtsm_probes_stat:streams()
.

streams_num() ->
  lists:foldl(fun(_E, Num) -> 1+Num end, 0, streams())
.

%% ------------------------------------------------------------------
%% Internal function Definitions
%% ------------------------------------------------------------------

start_probe(File, Config, List) ->
  case io:get_line(File, "") of
    eof  ->
      List;
    Line ->
      {Probe={Probe_addr, _Probe_port, _Probe_max}, List1} = process(string:tokens(Line,";\n"), List, [], Config),
      mtsm_probes_probe_sup:start_probe({Probe_addr, Probe, Config}),
      start_probe(File, Config, List1)
  end
.

process([Probe, Name, Max], List, Params, Config) ->
  io:format(" Max: ~p",[Max]),
  process([Probe, Name], List, [{max, to_integer(string:strip(Max))}|Params], Config)
;
process([Probe, Name], List, Params, Config) ->
  io:format(" Name: ~ts",[Name]),
  process([Probe], List, [{name, list_to_binary(string:strip(Name))}|Params], Config)
;
process([Probe], List, Params, Config) ->
  [Addr, Port] = parse_probe(Probe, Config),
  io:format(" ~p:~p~n",[Addr, Port]),
  {ok, Probe_addr}=inet:parse_address(Addr),
  {{Probe_addr, to_integer(Port), proplists:get_value(max, Params, 1)},
    [{Probe_addr, Params} | List]}
.

parse_probe(Probe_column, Config) ->
  case string:tokens(Probe_column,": ") of
    [Addr, Port] -> [Addr, Port];
    [Addr] -> [Addr, proplists:get_value(default_port, Config)]
  end
.

to_integer(Str) ->
  {Int, _Rest} = string:to_integer(Str),
  Int
.