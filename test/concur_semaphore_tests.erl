-module(concur_semaphore_tests).
-include_lib("eunit/include/eunit.hrl").

wait_for(Events) ->
  wait_for(Events, []).

wait_for([], _Stack) -> ok;
wait_for([{M, N} | Events], Stack) ->
  receive
    {M, _, N} = Event ->
      wait_for(Events, [Event | Stack]);
    {X, _, Y} = Event ->
      case lists:filter(fun({A, B}) -> A == X andalso B == Y end, Events) of
        [{X, Y} = ShortEvent] -> wait_for([{M, N} | Events -- [ShortEvent]], [Event | Stack]);
        [] -> throw({unexpected, Event, {expected, {M, N}, Stack}})
      end;
    Event -> throw({unexpected, Event, {expected, {M, N}, Stack}})
  after
    1_000 -> throw(timeout)
  end.

run_child(Parent, Name, N, Time) ->
  spawn(fun() ->
    concur_semaphore:call(Name, fun() ->
      Parent ! {starting, os:system_time(microsecond), N},
      timer:sleep(Time),
      Parent ! {ending, os:system_time(microsecond), N}
    end)
  end).

semaphore_n1_test() ->
  application:ensure_all_started(gproc),
  concur_semaphore_sup:start_link(1),
  concur_semaphore:reset(test),

  Parent = self(),
  Time = 20,
  Numbers = lists:seq(1, 50),

  [ run_child(Parent, test, N, Time) || N <- Numbers ],
  wait_for([ {M, N} || N <- Numbers, M <- [starting, ending] ]),
  ok.
