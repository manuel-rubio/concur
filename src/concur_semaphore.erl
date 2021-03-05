-module(concur_semaphore).

-behaviour(gen_statem).

-export([
  start_link/2,

  call/2,
  call/3,
  safe_call/2,
  safe_call/3,

  % "low level" API
  wait/2,
  release/1,
  reset/1
]).

-export([
  callback_mode/0,
  init/1,
  handle_event/4
]).

-define(SUPERVISOR, concur_semaphore_sup).

-record(state, {
  name,
  max_amount,

  running = #{},
  waiting = queue:new()
}).

-define(EXPIRATION_TIMEOUT, timer:minutes(1)).
-define(DEFAULT_WAIT_TIMEOUT, timer:seconds(5)).

% API

callback_mode() ->
  handle_event_function.

server_name(Name) ->
  {via, gproc, ?SUPERVISOR:gproc_name(Name)}.

start_link(MaxAmount, Name) ->
  ServerName = server_name(Name),
  gen_statem:start_link(ServerName, ?MODULE, [MaxAmount, Name], []).

call(Name, Fun) ->
  call(Name, ?DEFAULT_WAIT_TIMEOUT, Fun).

call(Name, Timeout, Fun) ->
  SemRef = wait(Name, Timeout),
  try Fun()
  after release(SemRef)
  end.

safe_call(Name, Fun) ->
  safe_call(Name, ?DEFAULT_WAIT_TIMEOUT, Fun).

safe_call(Name, Timeout, Fun) ->
  SemRef = safe_wait(Name, Timeout),
  try Fun()
  after release(SemRef)
  end.

wait(Name, Timeout) when Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0) ->
  SemPid = ?SUPERVISOR:ensure_started(Name),
  {ok, Ref} = gen_statem:call(SemPid, wait, {dirty_timeout, Timeout}),
  {SemPid, Ref}.

safe_wait(Name, Timeout) ->
  try wait(Name, Timeout)
  catch _:_ -> undefined
  end.

release({SemPid, Ref}) ->
  gen_statem:cast(SemPid, {release, self(), Ref});

release(undefined) ->
  ok.

reset(Name) ->
  case ?SUPERVISOR:lookup_pid(Name) of
    undefined ->
      not_found;
    Pid ->
      gen_statem:stop(Pid)
  end.

% gen server

init([MaxAmount, Name]) ->
  % psutils:md({?MODULE, Name, MaxAmount}),
  {ok, green, #state{name = Name, max_amount = MaxAmount}}.

add_waiting(From, State) ->
  State#state{
    waiting = queue:in(From, State#state.waiting)
  }.

add_running({Pid, _}, Ref, State) ->
  State#state{
    running = (State#state.running)#{Pid => Ref}
  }.

remove_running(Pid, State) ->
  State#state{
    running = maps:remove(Pid, State#state.running)
  }.

next_process(State) ->
  case queue:out(State#state.waiting) of
    {{value, From}, Waiting} ->
      {From, State#state{waiting = Waiting}};
    {empty, _Waiting} ->
      {undefined, State}
  end.

handle_event({call, {Pid, _} = From}, wait, _, #state{running = Procs}) when is_map_key(Pid, Procs) ->
  % a process is requesting a second semaphore while running?!? ... die!!!
  {keep_state_and_data, [
    {reply, From, deadlock},
    {next_event, cast, {release, Pid, maps:get(Pid, Procs)}}
  ]};

handle_event({call, {Pid, _} = From}, wait, green, State) ->
  Ref = monitor(process, Pid),
  NewState = add_running(From, Ref, State),
  Actions = [{reply, From, {ok, Ref}}],
  if
    State#state.max_amount == map_size(NewState#state.running) ->
      {next_state, red, NewState, Actions};
    true ->
      {keep_state, NewState, Actions}
  end;

handle_event({call, From}, wait, red, State) ->
  NewState = add_waiting(From, State),
  {keep_state, NewState};

handle_event(cast, {release, Pid, Ref}, green, State) ->
  demonitor(Ref, [flush]),
  case maps:get(Pid, State#state.running, undefined) of
    Ref ->
      NewState = remove_running(Pid, State),
      {keep_state, NewState};
    undefined ->
      keep_state_and_data
  end;

handle_event(cast, {release, Pid, Ref}, red, State) ->
  demonitor(Ref, [flush]),
  case maps:get(Pid, State#state.running, undefined) of
    Ref ->
      State0 = remove_running(Pid, State),
      case next_process(State0) of
        {{NewPid, _} = From, State1} ->
          NewRef = monitor(process, NewPid),
          State2 = add_running(From, NewRef, State1),
          Actions = [{reply, From, {ok, NewRef}}],
          {keep_state, State2, Actions};
        {undefined, State1} ->
          {next_state, green, State1}
      end;
    undefined ->
      keep_state_and_data
  end;

handle_event(info, {'DOWN', Ref, process, Pid, _Info}, _StateName, State) ->
  case maps:get(Pid, State#state.running, undefined) of
    Ref ->
      {keep_state_and_data, [{next_event, cast, {release, Pid, Ref}}]};
    undefined ->
      keep_state_and_data
  end;

handle_event(info, timeout, _StateName, _StateData) ->
  {stop, normal}.
