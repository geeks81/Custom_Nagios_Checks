-module(mpegtsmon_jsonrpc).

-include_lib("rfc4627_jsonrpc/include/rfc4627.hrl").
-include_lib("rfc4627_jsonrpc/include/rfc4627_jsonrpc.hrl").

-include("stream.hrl").

-behaviour(gen_server).

-export([start/1, start_httpd/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

start(List) ->
    {ok, Pid} = gen_server:start(?MODULE, [List], []),
    rfc4627_jsonrpc:register_service
      (Pid,
       rfc4627_jsonrpc:service(<<"mpegtsmon">>,
			       <<"urn:uuid:4ba40e2a-7f2a-41ba-99f1-204d5425393e">>,
			       <<"1.0">>,
			       [
             #service_proc{name = <<"list_all">>},
             #service_proc{name = <<"rate_all">>},
             #service_proc{name = <<"status_all">>},
             #service_proc{name = <<"params_all">>}
             ])
      )
.

start_httpd(List) ->
    ok = case rfc4627_jsonrpc:start() of
             {ok, _JsonrpcPid} -> ok;
             {error, {already_started, _JsonrpcPid}} -> ok
         end,
    ok = inets:start(),
    {ok, _HttpdPid} = inets:start(httpd, [{file, "httpd.conf"}]),
    start(List).

%---------------------------------------------------------------------------

init([List]) ->
  {ok, {List}}
.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({jsonrpc, <<"params_all">>, _ModData, []}, _From, State) ->
  {Streams} = State,
  List = lists:map(fun({Id, {_Port, Params}})->{id2bin(Id),{obj, Params}} end, Streams),
  {reply, {result, {obj, List}}, State}
;
handle_call({jsonrpc, <<"status_all">>, _ModData, []}, _From, State) ->
  List = lists:map(fun(Elem)->status_of(Elem) end, mpegtsmon_stat:list()),
  {reply, {result, {obj, List}}, State}
;
handle_call({jsonrpc, <<"rate_all">>, _ModData, []}, _From, State) ->
  List = lists:map(fun(Elem)->rate_of(Elem) end, mpegtsmon_stat:list()),
  {reply, {result, {obj, List}}, State}
;
handle_call({jsonrpc, <<"list_all">>, _ModData, []}, _From, State) ->
  List = lists:map(fun({_Id, Child, _Type, _Modules})->stream_of(Child) end,mpegtsmon_stream_sup:childrens()),
  {reply, {result, {obj, List}}, State}
.

handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in mpegtsmon_jsonrpc: ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in mpegtsmon_jsonrpc: ~p", [Info]),
    {noreply, State}.

mcast_of(Pid) ->
  case mpegtsmon_stream:mcast_of(Pid) of
    {error, _Error} ->
      <<"error">>;
    {Addr, Port} ->
      {obj,[{addr, id2bin(Addr)}, {port, Port}]}
  end
.

stream_of(Pid) ->
  case mpegtsmon_stream:stream_of(Pid) of
    {{error, _Error},_Pids, _Status} ->
      <<"error">>;
    {{Addr, Port},Pids, Status} ->
      {id2bin(Addr),
        {obj,[{addr, id2bin(Addr)}, {port, Port},{pids,Pids},
          {status,?RFC4627_FROM_RECORD(status,
            Status#status{bad_detail = ?RFC4627_FROM_RECORD(bad_detail,Status#status.bad_detail)})
          }]}
      }
  end
.

rate_of({Id, {Status, _Total}}) ->
  {id2bin(Id),
    {obj,[
      {byte_ps, Status#status.byte_ps},
      {discontinue_pi, Status#status.discontinue_pi},
      {nullpid_pi, Status#status.nullpid_pi}
    ]}
  }
.

status_of({Id, {Status, _Total}}) ->
  {id2bin(Id),
    {obj,[
      {is_ok, Status#status.is_ok},
      {details, ?RFC4627_FROM_RECORD(bad_detail,Status#status.bad_detail)}
    ]}
  }
.

id2bin(Addr) ->
  list_to_binary(mpegtsmon_stream:id2string(Addr))
.
