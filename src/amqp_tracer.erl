%%%-------------------------------------------------------------------
%%% @author Jack Tang <jack@taodinet.com>
%%% @copyright (C) 2013, Jack Tang
%%% @doc
%%%
%%% @end
%%% Created : 30 Oct 2013 by Jack Tang <jack@taodinet.com>
%%%-------------------------------------------------------------------
-module(amqp_tracer).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([trace_amqp/2,
         trace_amqp/3,
         trace_amqp/4,
         stop_trace/1,
         stop_trace/2,
         clear_all_traces/0,
         clear_all_traces/1,
         status/0]).

-define(SERVER, ?MODULE). 

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

trace_amqp(RoutingKey, Filter) ->
    trace_amqp(RoutingKey, Filter, debug).

trace_amqp(RoutingKey, Filter, Level) ->
    gen_server:cast(?SERVER, {trace, RoutingKey, Filter, Level}).

trace_amqp(distributed, RoutingKey, Filter, Level) ->
    lists:foreach(
      fun(Node) ->
              io:format("~p trace: ~p on level ~p~n", [Node, Filter, Level]),
              gen_server:cast({?SERVER, Node}, {trace, RoutingKey, Filter, Level})
      end, nodes()).


stop_trace({_Filter, _Level, _Target} = Trace) ->
    gen_server:cast(?SERVER, {stop_trace, Trace}).

stop_trace(distributed, {_, _, _} = Trace) ->
    lists:foreach(
      fun(Node) ->
              gen_server:cast({?SERVER, Node}, {stop_trace, Trace})
      end, nodes()).


clear_all_traces() ->
    gen_server:cast(?SERVER, clear_all_traces).

clear_all_traces(distributed) ->
    lists:foreach(
      fun(Node) ->
              gen_server:cast({?SERVER, Node}, clear_all_traces)
      end, nodes()).

status() ->
    lists:foreach(
     fun(Node) ->
             io:format("Lager status on node ~p: ~n", [Node]),
             case rpc:call(Node, lager, status, [], 60000) of
                 {badrpc, Reason} ->
                     io:format("RPC failed because of the reason: ~p", [Reason]);
                 _ -> ok
             end
     end, nodes()),
    ok.
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initiates the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({trace, RoutingKey, Filter, Level}, State) ->
    do_trace_amqp(RoutingKey, Filter, Level),
    {noreply, State};

handle_cast({stop_trace, Trace}, State) ->
    lager:stop_trace(Trace),
    {noreply, State};

handle_cast(clear_all_traces, State) ->
    lager:clear_all_traces(),
    {noreply, State}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

do_trace_amqp(RoutingKey, Filter, Level) ->
    Trace0 = { Filter, Level, {lager_amqp_backend, RoutingKey} },
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            Handlers = gen_event:which_handlers(lager_event),
            %% check if this file backend is already installed
            Res = case lists:member({lager_amqp_backend, RoutingKey}, Handlers) of
                false ->
                    %% install the handler, https://github.com/basho/lager/issues/65
                    supervisor:start_child(lager_handler_watcher_sup,
                        [lager_event, {lager_amqp_backend, RoutingKey},
                                      [{routing_key,<<"test_amqp">>},{level,none}] ]);
                _ ->
                    {ok, exists}
            end,
            case Res of
              {ok, _} ->
                add_trace_to_loglevel_config(Trace),
                {ok, Trace};
              {error, _} = E ->
                E
            end;
        Error ->
            Error
    
    end.

add_trace_to_loglevel_config(Trace) ->
    {MinLevel, Traces} = lager_config:get(loglevel),
    case lists:member(Trace, Traces) of
        false ->
            NewTraces = [Trace|Traces],
            lager_util:trace_filter([ element(1, T) || T <- NewTraces]),
            lager_config:set(loglevel, {MinLevel, [Trace|Traces]});
        _ ->
            ok
    end.
