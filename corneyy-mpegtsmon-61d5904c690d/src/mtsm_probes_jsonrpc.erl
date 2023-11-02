-module(mtsm_probes_jsonrpc).
-behaviour(gen_server).

-include_lib("rfc4627_jsonrpc/include/rfc4627.hrl").
-include_lib("rfc4627_jsonrpc/include/rfc4627_jsonrpc.hrl").

-include("probe.hrl").

%% API
-export([start_link/0]).
-export([probes/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

probes(List) ->
  gen_server:cast(?MODULE,{set_probes_list, List})
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
  rfc4627_jsonrpc:register_service
  (self(),
    rfc4627_jsonrpc:service(<<"probes">>,
      <<"urn:uuid:57FBABAC-4AAE-11E6-B296-8A06E8BF5E87">>,
      <<"1.0">>,
      [
        #service_proc{name = <<"list">>},
        #service_proc{name = <<"streams">>}
      ])
  ),
  {ok, {[]}}
.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({jsonrpc, <<"streams">>, _ModData, []}, _From, State) ->
  {Probes} = State,
  List = lists:map(fun({Id, _Params})->
    {id2bin(Id),{obj, mtsm_probes_stat:streams_state(Id, fun stream_state_to_json/1)}} end, Probes),
  {reply, {result, {obj, List}}, State}
;
handle_call({jsonrpc, <<"list">>, _ModData, []}, _From, State) ->
  {Probes} = State,
  List = lists:map(fun({Id, Params})->
    {obj, [{id, id2bin(Id)}, {params, {obj, Params}},
      {state, ?RFC4627_FROM_RECORD(probe_state, mtsm_probes_stat:state(Id))}]
    } end, Probes),
  {reply, {result, List}, State}
.

handle_cast({set_probes_list, List}, _State) ->
  {noreply, {List}}
;
handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in mtsm_probes_jsonrpc: ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in mtsm_probes_jsonrpc: ~p", [Info]),
    {noreply, State}.

id2bin(Addr) ->
  list_to_binary(mpegtsmon_stream:id2string(Addr))
.

stream_state_to_json({{Addr, _Port}, {_Last_time, Status, Cc, Pktin}}) ->
  {id2bin(Addr), {obj, [{status, Status}, {continuity_errors, Cc}, {recv_bytes, Pktin*188}]}}
.