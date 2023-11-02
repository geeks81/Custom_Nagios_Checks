-module(mpegtsmon_esi).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([thumb/2, thumb/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

thumb(Data, Stream_id) ->
  gen_server:cast(?MODULE,{set_thumb, Data, Stream_id})
.

%% TODO concurrent processing

thumb(SessID, _Env, Input) ->
  gen_server:call(?MODULE,{deliver_thumb, SessID, string:sub_word(Input, 1, $?)})
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
  load(not_ready),
  load(bad),
  {ok, no_state}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({deliver_thumb, SessID, Stream_id},_From, State) ->
  case get(Stream_id) of
    undefined ->
      mod_esi:deliver(SessID, "Content-Type: image/png\r\n\r\n"),
      mod_esi:deliver(SessID, get(not_ready));
    wait ->
      mod_esi:deliver(SessID, "Content-Type: image/png\r\n\r\n"),
      mod_esi:deliver(SessID, get(not_ready));
    bad ->
      mod_esi:deliver(SessID, "Content-Type: image/png\r\n\r\n"),
      mod_esi:deliver(SessID, get(bad));
    Thumb ->
      mod_esi:deliver(SessID, "Content-Type: image/jpeg\r\n\r\n"),
      mod_esi:deliver(SessID, Thumb)
  end,
  {reply, ok, State}
.

handle_cast({set_thumb, Data, Stream_id}, State) ->
  put(Stream_id, Data),
  {noreply, State}
;
handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in mpegtsmon_jsonrpc: ~p", [Request]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in mpegtsmon_jsonrpc: ~p", [Info]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
load(not_ready) ->
  put(not_ready, load("./server_root/html/not_ready.png"))
;
load(bad) ->
  put(bad, load("./server_root/html/bad.png"))
;
load(File) ->
  {ok, Data} = file:read_file(File),
  Data
.
