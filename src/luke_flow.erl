%% Copyright (c) 2010 Basho Technologies, Inc.  All Rights Reserved.

%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc Manages the execution of a flow
-module(luke_flow).

-behaviour(gen_fsm).

%% API
-export([start_link/5,
         add_inputs/2,
         finish_inputs/1,
         collect_output/2]).

%% FSM states
-export([get_phases/1,
         executing/2,
         executing/3]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {flow_id,
                fsms,
                client,
                flow_timeout,
                tref,
                xformer,
                cache=orddict:new(),
                results=[]}).

%% @doc Add inputs to the flow. Inputs will be sent to the
%%      first phase
%% @spec add_inputs(pid(), any()) -> ok
add_inputs(FlowPid, Inputs) ->
    Timeout = get_timeout(FlowPid),
    gen_fsm:sync_send_event(FlowPid, {inputs, Inputs}, Timeout).

%% @doc Informs the phases all inputs are complete.
%% @spec finish_inputs(pid()) -> ok
finish_inputs(FlowPid) ->
    gen_fsm:send_event(FlowPid, inputs_done).

%% @doc Collects flow output. This function will block
%%      until the flow completes or exceeds the flow_timeout.
%% @spec collect_output(any(), integer()) -> [any()] | {error, any()}
collect_output(FlowId, Timeout) ->
    collect_output(FlowId, Timeout, dict:new()).

%% @doc Retrieve configured timeout for flow
%% @spec get_timeout(pid()) -> integer()
get_timeout(FlowPid) ->
    gen_fsm:sync_send_event(FlowPid, get_timeout).

%% @doc Returns the pids for each phase. Intended for
%%      testing only
%% @spec get_phases(pid()) -> [pid()]
get_phases(FlowPid) ->
    gen_fsm:sync_send_event(FlowPid, get_phases).

start_link(Client, FlowId, FlowDesc, FlowTransformer, Timeout) when is_list(FlowDesc),
                                                                    is_pid(Client) ->
    gen_fsm:start_link(?MODULE, [Client, FlowId, FlowDesc, FlowTransformer, Timeout], []).

init([Client, FlowId, FlowDesc, FlowTransformer, Timeout]) ->
    process_flag(trap_exit, true),
    Tref = case Timeout of
               infinity ->
                   undefined;
               _ ->
                   {ok, T} = timer:send_after(Timeout, flow_timeout),
                   T
           end,
    case start_phases(FlowDesc, Timeout) of
        {ok, FSMs} ->
            {ok, executing, #state{fsms=FSMs, flow_id=FlowId, flow_timeout=Timeout, client=Client, xformer=FlowTransformer, tref=Tref}};
        Error ->
            {stop, Error}
    end.

executing(inputs_done, #state{fsms=[H|_]}=State) ->
    luke_phases:send_inputs_done(H),
    {next_state, executing, State};
executing(timeout, #state{client=Client, flow_id=FlowId}=State) ->
    Client ! {flow_results, FlowId, done},
    {stop, normal, State};
executing({results, done}, #state{client=Client, flow_id=FlowId}=State) ->
    Client ! {flow_results, FlowId, done},
    {stop, normal, State};
executing({results, PhaseId, Result0}, #state{client=Client, flow_id=FlowId, xformer=XFormer}=State) ->
    Result = transform_results(XFormer, Result0),
    Client ! {flow_results, PhaseId, FlowId, Result},
    {next_state, executing, State}.

executing(get_timeout, _From, #state{flow_timeout=Timeout}=State) ->
    {reply, Timeout, executing, State};
executing({inputs, Inputs}, _From, #state{fsms=[H|_], flow_timeout=Timeout}=State) ->
    luke_phases:send_sync_inputs(H, Inputs, Timeout),
    {reply, ok, executing, State};

executing({cache_value, Key, Value}, _From, #state{cache=Cache0}=State) ->
    Cache = orddict:store(Key, Value, Cache0),
    {reply, ok, executing, State#state{cache=Cache}};
executing({check_cache, Key}, _From, #state{cache=Cache}=State) ->
    Reply = case orddict:is_key(Key, Cache) of
                false ->
                    not_found;
                true ->
                    orddict:fetch(Key, Cache)
            end,
    {reply, Reply, executing, State};
executing(get_phases, _From, #state{fsms=FSMs}=State) ->
    {reply, FSMs, executing, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ignored, StateName, State}.

handle_info(flow_timeout, _StateName, #state{flow_id=FlowId, client=Client}=State) ->
    Client ! {flow_error, FlowId, {error, timeout}},
    {stop, {error, flow_timeout}, State};
handle_info({'EXIT', _Pid, normal}, StateName, State) ->
    {next_state, StateName, State};
handle_info({'EXIT', _Pid, Reason}, _StateName, #state{flow_id=FlowId, client=Client}=State) ->
    Client ! {flow_error, FlowId, Reason},
    {stop, {error, {phase_error, Reason}}, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, #state{tref=Tref}) ->
    timer:cancel(Tref),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions
start_phases(FlowDesc, Timeout) ->
    start_phases(lists:reverse(FlowDesc), length(FlowDesc) - 1, Timeout, []).

start_phases([], _Id, _Timeout, Accum) ->
    {ok, Accum};
start_phases([{PhaseMod, Behaviors, Args}|T], Id, Timeout, Accum) ->
    NextFSM = next_fsm(Accum),
    case proplists:get_value(converge, Behaviors) of
        undefined ->
            case luke_phase_sup:new_phase(Id, PhaseMod, Behaviors, NextFSM, self(),
                                          Timeout, Args) of
                {ok, Pid} ->
                    erlang:link(Pid),
                    start_phases(T, Id - 1, Timeout, [Pid|Accum]);
                Error ->
                    Error
            end;
        InstanceCount ->
            Pids = start_converging_phases(Id, PhaseMod, Behaviors, NextFSM, self(),
                                           Timeout, Args, InstanceCount),
            start_phases(T, Id - 1, Timeout, [Pids|Accum])
    end.

collect_output(FlowId, Timeout, Accum) ->
    receive
        {flow_results, FlowId, done} ->
            {ok, finalize_results(Accum)};
        {flow_results, PhaseId, FlowId, Results} ->
            collect_output(FlowId, Timeout, accumulate_results(PhaseId, Results, Accum));
        {flow_error, FlowId, Error} ->
            Error
    after Timeout ->
            case dict:size(Accum) of
                0 ->
                    {error, timeout};
                _ ->
                    {ok, finalize_results(Accum)}
            end
    end.

next_fsm(Accum) ->
 if
     length(Accum) == 0 ->
         undefined;
     true ->
         case hd(Accum) of
             P when is_pid(P) ->
                 [P];
             P ->
                 P
         end
 end.

start_converging_phases(Id, PhaseMod, Behaviors0, NextFSM, Flow,
                        Timeout, Args, Count) ->
    Behaviors = [normalize_behavior(B) || B <- Behaviors0],
    Pids = start_converging_phases(Id, PhaseMod, Behaviors, NextFSM, Flow,
                                   Timeout, Args, Count, []),
    [Leader|_] = Pids,
    lists:foreach(fun(P) -> luke_phase:partners(P, Leader, Pids) end, Pids),
    Pids.

start_converging_phases(_Id, _PhaseMod, _Behaviors, _NextFSM, _Flow,
                        _Timeout, _Args, 0, Accum) ->
    Accum;
start_converging_phases(Id, PhaseMod, Behaviors, NextFSM, Flow,
                        Timeout, Args, Count, Accum) ->
    case luke_phase_sup:new_phase(Id, PhaseMod, Behaviors, NextFSM, Flow,
                                  Timeout, Args) of
        {ok, Pid} ->
            erlang:link(Pid),
            start_converging_phases(Id, PhaseMod, Behaviors, NextFSM, Flow,
                                    Timeout, Args, Count - 1, [Pid|Accum]);
        Error ->
            throw(Error)
    end.

normalize_behavior({converge, _}) ->
    converge;
normalize_behavior(Behavior) ->
    Behavior.

finalize_results(Accum) ->
    case [lists:append(R) || {_, R} <- lists:sort(dict:to_list(Accum))] of
        [R] ->
            R;
        R ->
            R
    end.

accumulate_results(PhaseId, Results, Accum) ->
    case dict:find(PhaseId, Accum) of
        error ->
            dict:store(PhaseId, [Results], Accum);
        {ok, PhaseAccum} ->
            dict:store(PhaseId, [Results|PhaseAccum], Accum)
    end.

transform_results(undefined, Results) ->
    Results;
transform_results(Xformer, Results) when is_list(Results) ->
    [Xformer(R) || R <- Results];
transform_results(Xformer, Results) ->
    Xformer(Results).
