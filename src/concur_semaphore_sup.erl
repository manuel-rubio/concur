-module(concur_semaphore_sup).

-behaviour(supervisor).

%% API
-export([
  start_link/1,
  ensure_started/1,
  lookup_pid/1,
  gproc_name/1,

  % supervisor callbacks
  init/1
]).

-define(WORKER, concur_semaphore).

start_link(MaxAmount) ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, [MaxAmount]).

init([MaxAmount]) ->
  SupervisorSpecification = #{
    strategy => simple_one_for_one,
    intensity => 10,
    period => 60
  },
  ChildSpec = [
    #{
      id => ?WORKER,
      start => {?WORKER, start_link, [MaxAmount]},
      shutdown => 100
    }
  ],
  {ok, {SupervisorSpecification, ChildSpec}}.

start_child(Name) ->
  supervisor:start_child(?MODULE, [Name]).

ensure_started(Name) ->
  GProcName = gproc_name(Name),
  try
    gproc:lookup_pid(GProcName)
  catch
    error:badarg ->
      case start_child(Name) of
        {ok, Pid} -> Pid;
        {ok, Pid, _} -> Pid;
        {error, {already_started, Pid}} -> Pid;
        {error, running} -> gproc:lookup_pid(GProcName)
      end
  end.

gproc_name(Name) ->  {n, l, {?MODULE, ?WORKER, Name}}.

lookup_pid(Name) ->
  try gproc:lookup_pid(gproc_name(Name))
  catch error:badarg -> undefined
  end.
