%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_server_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1, pull_plug/1]).

start_link() ->
    application:start(os_mon),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    pre_start(),
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          get_child_specs()}}.

pre_start() ->
    misc:make_pidfile(),
    misc:ping_jointo().

get_child_specs() ->
    good_children() ++ bad_children().


%% Children that needn't be restarted when we pull the plug. These
%% cannot crash or hang if Mnesia is down, but they can depend on it
%% for proper operation unless they will cause other good children to
%% crash without it.
good_children() ->
    [{ns_config_sup, {ns_config_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_config_sup]},

     %% ns_log starts after ns_config because it needs the config to
     %% find where to persist the logs
     {ns_log, {ns_log, start_link, []},
      permanent, 10, worker, [ns_log]},

     {ns_log_events, {gen_event, start_link, [{local, ns_log_events}]},
      permanent, 10, worker, dynamic},

     {ns_mail_sup, {ns_mail_sup, start_link, []},
      permanent, infinity, supervisor, [ns_mail_sup]},

     {ns_node_disco_sup, {ns_node_disco_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_node_disco_sup]},

     {menelaus, {menelaus_app, start_subapp, []},
      permanent, infinity, supervisor,
      [menelaus_app]},

     {ns_port_sup, {ns_port_sup, start_link, []},
      permanent, 10, worker,
      [ns_port_sup]},

     {ns_tick_event, {gen_event, start_link, [{local, ns_tick_event}]},
      permanent, 10, worker, dynamic},

     {ns_stats_event, {gen_event, start_link, [{local, ns_stats_event}]},
      permanent, 10, worker, dynamic},

     {ns_heart, {ns_heart, start_link, []},
      permanent, 10, worker, [ns_heart]},

     {ns_orchestrator, {ns_orchestrator, start_link, []},
      permanent, 20, worker, [ns_orchestrator]}
    ].


%% Children that get restarted if we pull the plug. These can depend
%% on Mnesia.
bad_children() ->
    [{ns_moxi_sup, {ns_moxi_sup, start_link, []},
      permanent, infinity, supervisor,
      [ns_moxi_sup]},

     {ns_vbm_sup, {ns_vbm_sup, start_link, []},
      permanent, infinity, supervisor, [ns_vbm_sup]},

     {ns_tick, {ns_tick, start_link, []},
      permanent, 10, worker, [ns_tick]},

     {ns_bucket_sup, {ns_bucket_sup, start_link, []},
      permanent, infinity, supervisor, [ns_bucket_sup]},

     {ns_doctor, {ns_doctor, start_link, []},
      permanent, 10, worker, [ns_doctor]}].


%% beware that if it's called from one of restarted childs it won't
%% work. This can be allowed with further work here.
pull_plug(Fun) ->
    GoodChildren = [Id || {Id, _, _, _, _, _} <- good_children()],
    BadChildren = [Id || {Id, _, _, _, _, _} <- bad_children()],
    error_logger:info_msg("~p plug pulled.  Killing ~p, keeping ~p~n",
                          [?MODULE, BadChildren, GoodChildren]),
    lists:foreach(fun(C) -> ok = supervisor:terminate_child(?MODULE, C) end,
                  lists:reverse(BadChildren)),
    Fun(),
    lists:foreach(fun(C) ->
                          R = supervisor:restart_child(?MODULE, C),
                          error_logger:info_msg("Restarting ~p: ~p~n", [C, R])
                  end,
                  BadChildren).
