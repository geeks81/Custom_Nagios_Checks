-module(mpegtsmon_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
  {ok, { {one_for_one, 5, 10}, [
    ?CHILD(mpegtsmon_stream_sup, supervisor),
    ?CHILD(mpegtsmon_thumb_sup, supervisor),
    ?CHILD(mpegtsmon_thumb_disp, worker),
    ?CHILD(mpegtsmon_esi, worker),
    ?CHILD(mpegtsmon_stat, worker)
  ]}}
.

