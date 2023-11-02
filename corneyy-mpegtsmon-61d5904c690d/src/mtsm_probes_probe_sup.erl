-module(mtsm_probes_probe_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Stream API
-export([start_probe/1, childrens/0]).

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
  {ok, { {simple_one_for_one, 5, 10}, [ ?CHILD(mtsm_probes_probe, worker)]} }.

start_probe(Arg) ->
  supervisor:start_child(?MODULE, [Arg])
.

childrens() ->
  supervisor:which_children(?MODULE)
.
