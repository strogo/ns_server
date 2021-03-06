%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_web_buckets).

-author('NorthScale <info@northscale.com>').

-include("menelaus_web.hrl").

-export([all_accessible_bucket_names/2,
         checking_bucket_access/4,
         handle_bucket_list/2,
         handle_bucket_info/5,
         build_bucket_info/5,
         build_bucket_info/4,
         handle_sasl_buckets_streaming/2,
         handle_bucket_info_streaming/5,
         handle_bucket_info_streaming/6,
         handle_bucket_delete/3,
         handle_bucket_update/3,
         handle_bucket_create/2,
         handle_bucket_flush/3,
         parse_bucket_params/5,
         redirect_to_bucket/3]).

-import(menelaus_util,
        [server_header/0,
         reply_json/2,
         concat_url_path/1,
         reply_json/3]).

all_accessible_bucket_names(_PoolId, Req) ->
    BucketsAll = ns_bucket:get_bucket_names(),
    menelaus_auth:filter_accessible_buckets(BucketsAll, Req).

checking_bucket_access(_PoolId, Id, Req, Body) ->
    E404 = make_ref(),
    try
        case menelaus_auth:is_bucket_accessible({Id, fakebucket}, Req) of
            true -> apply(Body, [fakepool, fakebucket]);
            _ -> menelaus_auth:require_auth(Req)
        end
    catch
        exit:E404 ->
            Req:respond({404, server_header(), "Requested resource not found.\r\n"})
    end.

handle_bucket_list(Id, Req) ->
    BucketNames = lists:sort(fun (A,B) -> A =< B end,
                             all_accessible_bucket_names(fakepool, Req)),
    LocalAddr = menelaus_util:local_addr(Req),
    BucketsInfo = [build_bucket_info(Id, Name, fakepool, LocalAddr)
                   || Name <- BucketNames],
    reply_json(Req, BucketsInfo).

handle_bucket_info(PoolId, Id, Req, Pool, _Bucket) ->
    case ns_bucket:get_bucket(Id) of
        not_present -> Req:respond({404, server_header(), "The bucket was not found.\r\n"});
        _ -> reply_json(Req, build_bucket_info(PoolId, Id, Pool, menelaus_util:local_addr(Req)))
    end.

build_bucket_info(PoolId, Id, Pool, LocalAddr) ->
    build_bucket_info(PoolId, Id, Pool, normal, LocalAddr).

build_bucket_info(PoolId, Id, Pool, InfoLevel, LocalAddr) ->
    StatsUri = list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id, "stats"])),
    Nodes = menelaus_web:build_nodes_info(Pool, false, InfoLevel, LocalAddr),
    {ok, BucketConfig} = ns_bucket:get_bucket(Id),
    Suffix = case InfoLevel of
                 stable -> [];
                 normal ->
                     [{replicaNumber, ns_bucket:num_replicas(BucketConfig)},
                      {quota, {struct, [{ram, ns_bucket:ram_quota(BucketConfig)},
                                        {hdd, ns_bucket:hdd_quota(BucketConfig)}]}},
                      {basicStats, {struct, menelaus_stats:basic_stats(PoolId, Id)}}]
             end,
    {struct, [{name, list_to_binary(Id)},
              {bucketType, ns_bucket:bucket_type(BucketConfig)},
              {authType, misc:expect_prop_value(auth_type, BucketConfig)},
              {saslPassword, list_to_binary(proplists:get_value(sasl_password, BucketConfig, ""))},
              {proxyPort, proplists:get_value(moxi_port, BucketConfig, 0)},
              {uri, list_to_binary(concat_url_path(["pools", PoolId, "buckets", Id]))},
              {streamingUri, list_to_binary(concat_url_path(["pools", PoolId, "bucketsStreaming", Id]))},
              %% TODO: this should be under a controllers/ kind of namespacing
              {flushCacheUri, list_to_binary(concat_url_path(["pools", PoolId,
                                                              "buckets", Id, "controller", "doFlush"]))},
              {nodes, Nodes},
              {stats, {struct, [{uri, StatsUri}]}},
              {vBucketServerMap, ns_bucket:json_map(Id, LocalAddr)}
              | Suffix]}.

handle_sasl_buckets_streaming(_PoolId, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun (_) ->
                SASLBuckets = lists:filter(fun ({_, BucketInfo}) ->
                                                   ns_bucket:auth_type(BucketInfo) =:= sasl
                                           end, ns_bucket:get_buckets()),
                List = lists:map(fun ({Name, _BucketInfo}) ->
                                         MapStruct = ns_bucket:json_map(Name, LocalAddr),
                                         {struct, [{name, list_to_binary(Name)},
                                                   {vBucketServerMap, MapStruct}]}
                                 end, SASLBuckets),
                {struct, [{buckets, List}]}
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket) ->
    handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, stable).

handle_bucket_info_streaming(PoolId, Id, Req, Pool, _Bucket, ForceInfoLevel) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun(InfoLevel) ->
                case ForceInfoLevel of
                    undefined -> build_bucket_info(PoolId, Id, Pool, InfoLevel, LocalAddr);
                    _         -> build_bucket_info(PoolId, Id, Pool, ForceInfoLevel, LocalAddr)
                end
        end,
    menelaus_web:handle_streaming(F, Req, undefined).

handle_bucket_delete(_PoolId, BucketId, Req) ->
    case BucketId of
        %% just ignore that for now
        "default" ->
            Req:respond({200, server_header(), []});
        _ -> case ns_bucket:delete_bucket(BucketId) of
                 ok ->
                     ?MENELAUS_WEB_LOG(?BUCKET_DELETED, "Deleted bucket \"~s\"~n", [BucketId]),
                     Req:respond({200, server_header(), []});
                 {exit, {not_found, _}, _} ->
                     Req:respond({404, server_header(), "The bucket to be deleted was not found.\r\n"})
             end
    end.

redirect_to_bucket(Req, PoolId, BucketId) ->
    Req:respond({302, [{"Location", concat_url_path(["pools", PoolId, "buckets", BucketId])}
                       | server_header()],
                 ""}).

%% returns pprop list with only props useful for ns_bucket
extract_bucket_props(Props) ->
    [X || X <- [lists:keyfind(Y, 1, Props) || Y <- [num_replicas, ram_quota, hdd_quota, auth_type, sasl_password, moxi_port]],
          X =/= false].

handle_bucket_update(_PoolId, BucketId, Req) ->
    Params = Req:parse_post(),
    handle_bucket_update_inner(BucketId, Req, Params, 32).

handle_bucket_update_inner(_BucketId, _Req, _Params, 0) ->
    exit(bucket_update_loop);
handle_bucket_update_inner(BucketId, Req, Params, Limit) ->
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly,
          parse_bucket_params(false,
                              BucketId,
                              Params,
                              ns_bucket:get_buckets(),
                              ns_storage_conf:cluster_storage_info())} of
        {_, {errors, Errors, JSONSummaries}} ->
            RV = {struct, [{errors, {struct, Errors}},
                           {summaries, {struct, JSONSummaries}}]},
            reply_json(Req, RV, 400);
        {false, {ok, ParsedProps, _}} ->
            BucketType = proplists:get_value(bucketType, ParsedProps),
            UpdatedProps0 = extract_bucket_props(ParsedProps),
            UpdatedProps = case BucketId of
                               "default" -> lists:keyreplace(sasl_password, 1, UpdatedProps0, {sasl_password, ""});
                               _ -> UpdatedProps0
                           end,
            case ns_bucket:update_bucket_props(BucketType, BucketId, UpdatedProps) of
                ok ->
                    Req:respond({200, server_header(), []});
                {exit, {not_found, _}, _} ->
                    %% if this happens then our validation raced, so repeat everything
                    handle_bucket_update_inner(BucketId, Req, Params, Limit-1)
            end;
        {true, {ok, _, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, []}},
                                      {summaries, {struct, JSONSummaries}}]}, 200)
    end.

handle_bucket_create(PoolId, Req) ->
    Params = Req:parse_post(),
    Name = proplists:get_value("name", Params),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly,
          parse_bucket_params(true,
                              Name,
                              Params,
                              ns_bucket:get_buckets(),
                              ns_storage_conf:cluster_storage_info())} of
        {_, {errors, Errors, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}},
                                      {summaries, {struct, JSONSummaries}}]}, 400);
        {false, {ok, ParsedProps, _}} ->
            BucketType = proplists:get_value(bucketType, ParsedProps),
            BucketProps = extract_bucket_props(ParsedProps),
            case ns_orchestrator:create_bucket(BucketType, Name, BucketProps) of
                ok ->
                    ?MENELAUS_WEB_LOG(?BUCKET_CREATED, "Created bucket \"~s\" of type: ~s~n", [Name, BucketType]),
                    redirect_to_bucket(Req, PoolId, Name);
                %% TODO: check that!
                {exit, {already_exists, _}, _} ->
                    reply_json(Req, {struct, [{name, <<"Bucket with given name already exists">>}]}, 400);
                rebalance_running ->
                    %% TODO: fix that
                    reply_json(Req, [], 200)
            end;
        {true, {ok, _, JSONSummaries}} ->
            reply_json(Req, {struct, [{errors, {struct, []}},
                                      {summaries, {struct, JSONSummaries}}]}, 200)
    end.

handle_bucket_flush(PoolId, Id, Req) ->
    ns_log:log(?MODULE, 0005, "Flushing pool ~p bucket ~p from node ~p",
               [PoolId, Id, erlang:node()]),
    Req:respond({400, server_header(), "Flushing is not currently implemented."}).

-record(ram_summary, {
          total,                                % total cluster quota
          other_buckets,
          this_alloc,
          this_used,                            % part of this bucket which is used already
          free}).                               % total - other_buckets - this_alloc.
                                                % So it's: Amount of cluster quota available for allocation

-record(hdd_summary, {
          total,                                % total cluster disk space
          other_data,                           % disk space used by something other than our data
          other_buckets,                        % space allocated for other buckets
          this_alloc,                           % space allocated for this bucket
          this_used,                            % space already used by this bucket
          free}).                               % total - other_data - other_buckets - this_alloc
                                                % So it's kind of: Amount of cluster disk space available of allocation,
                                                % but with a number of 'but's.

parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals) ->
    UsageGetter = fun (ram, Name) ->
                          menelaus_stats:bucket_ram_usage(Name);
                      (hdd, all) ->
                          lists:sum([menelaus_stats:bucket_disk_usage(X)
                                     || {X, _} <- AllBuckets]);
                      (hdd, Name) ->
                          menelaus_stats:bucket_disk_usage(Name)
                  end,
    parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, UsageGetter).

parse_bucket_params(IsNew, BucketName, Params, AllBuckets, ClusterStorageTotals, UsageGetter) ->
    {OKs, Errors} = basic_bucket_params_screening(IsNew, BucketName,
                                                  Params, AllBuckets),
    CurrentBucket = proplists:get_value(currentBucket, OKs),
    HasRAMQuota = lists:keyfind(ram_quota, 1, OKs) =/= false,
    RAMSummary = if
                     HasRAMQuota ->
                         interpret_ram_quota(CurrentBucket, OKs, ClusterStorageTotals, UsageGetter);
                     true ->
                         undefined
                 end,
    HasHDDQuota = lists:keyfind(hdd_quota, 1, OKs) =/= false,
    HDDSummary = if
                     HasHDDQuota ->
                         interpret_hdd_quota(CurrentBucket, OKs, ClusterStorageTotals, UsageGetter);
                     true -> undefined
                 end,
    JSONSummaries = [X || X <- [case RAMSummary of
                                    undefined -> undefined;
                                    _ -> {ramSummary, {struct, ram_summary_to_proplist(RAMSummary)}}
                                end,
                                case HDDSummary of
                                    undefined -> undefined;
                                    _ -> {hddSummary, {struct, hdd_summary_to_proplist(HDDSummary)}}
                                end],
                          X =/= undefined],
    Errors2 = case {CurrentBucket, IsNew} of
                  {undefined, _} -> Errors;
                  {_, true} -> Errors;
                  {_, false} ->
                      case {proplists:get_value(bucketType, OKs),
                            ns_bucket:bucket_type(CurrentBucket)} of
                          {undefined, _} -> Errors;
                          {NewType, NewType} -> Errors;
                          {_NewType, _OldType} ->
                              [{bucketType, <<"Cannot change bucket type">>}
                               | Errors]
                      end
              end,
    RAMErrors =
        if
            RAMSummary =:= undefined ->
                [];
            RAMSummary#ram_summary.free < 0 ->
                [{ramQuotaMB, <<"This bucket doesn't fit cluster RAM quota">>}];
            RAMSummary#ram_summary.this_alloc < RAMSummary#ram_summary.this_used ->
                [{ramQuotaMB, <<"Cannot decrease below usage">>}];
            true ->
                []
        end,
    HDDErrors =
        if
            HDDSummary =:= undefined ->
                [];
            HDDSummary#hdd_summary.this_alloc < HDDSummary#hdd_summary.this_used ->
                [{hddQuotaGB, <<"Cannot decrease below usage">>}];
            RAMSummary =/= undefined andalso HDDSummary#hdd_summary.this_alloc < RAMSummary#ram_summary.this_alloc ->
                [{hddQuotaGB, <<"Disk quota less that RAM quota doesn't make sense">>}];
            true ->
                []
        end,
    TotalErrors = RAMErrors ++ HDDErrors ++ Errors2,
    if
        TotalErrors =:= [] ->
            {ok, OKs, JSONSummaries};
        true ->
            {errors, TotalErrors, JSONSummaries}
    end.

basic_bucket_params_screening(IsNew, BucketNames, Params, AllBuckets) ->
    AuthType = case proplists:get_value("authType", Params) of
                   "none" -> none;
                   "sasl" -> sasl;
                   _ -> {crap, <<"invalid authType">>} % this is not for end users
               end,
    case AuthType of
        {crap, Crap} = Crap -> {[], [{authType, Crap}]};
        _ -> basic_bucket_params_screening_tail(IsNew, BucketNames, Params, AllBuckets, AuthType)
    end.

basic_bucket_params_screening_tail(IsNew, BucketName, Params, AllBuckets, AuthType) ->
    BucketConfig = lists:keyfind(BucketName, 1, AllBuckets),
    Candidates0 = [{ok, name, BucketName},
                   {ok, auth_type, AuthType},
                   case IsNew of
                       true ->
                           case BucketConfig of
                               false ->
                                   case ns_bucket:is_valid_bucket_name(BucketName) of
                                       false ->
                                           {errors, name, <<"Bucket name can only contain characters in range A-Z, a-z, 0-9 as well as underscore, period, dash & percent. Consult the documentation.">>};
                                       _ ->
                                           undefined
                                   end;
                               _ ->
                                   {error, name, <<"Bucket with given name already exists">>}
                           end;
                       _ ->
                           case BucketConfig of
                               false ->
                                   {error, name, <<"Bucket with given name doesn't exist">>};
                               {_, X} ->
                                   {ok, currentBucket, X}
                           end
                   end,
                   case BucketName of
                       [] ->
                           {error, name, <<"Bucket name cannot be empty">>};
                       _ -> undefined
                   end,
                   case AuthType of
                       none ->
                           case menelaus_util:parse_validate_number(proplists:get_value("proxyPort", Params),
                                                                    1025, 65535) of
                               {ok, PP} -> {ok, moxi_port, PP};
                               _ -> {error, proxyPort, <<"proxy port is invalid">>}
                           end;
                       sasl ->
                           {ok, sasl_password, proplists:get_value("saslPassword", Params, "")}
                   end,
                   parse_validate_ram_quota(proplists:get_value("ramQuotaMB", Params))],
    BucketType = if
                     (not IsNew) andalso BucketConfig =/= false ->
                         ns_bucket:bucket_type(BucketConfig);
                     true ->
                         case proplists:get_value("bucketType", Params) of
                             "memcache" -> memcache;
                             "membase" -> membase;
                             undefined -> membase;
                             _ -> invalid
                         end
                 end,
    Candidates = case BucketType of
                     memcache ->
                         [{ok, bucketType, memcache}
                          | Candidates0];
                     membase ->
                         [{ok, bucketType, membase},
                          parse_validate_replicas_number(proplists:get_value("replicaNumber", Params)),
                          parse_validate_hdd_quota(proplists:get_value("hddQuotaGB", Params))
                          | Candidates0];
                     _ ->
                         [{error, bucketType, <<"invalid bucket type">>}
                          | Candidates0]
                 end,
    {[{K,V} || {ok, K, V} <- Candidates],
     [{K,V} || {error, K, V} <- Candidates]}.

-define(PRAM(K, KO), {KO, V#ram_summary.K}).
ram_summary_to_proplist(V) ->
    [?PRAM(total, total),
     ?PRAM(other_buckets, otherBuckets),
     ?PRAM(this_alloc, thisAlloc),
     ?PRAM(this_used, thisUsed),
     ?PRAM(free, free)].

interpret_ram_quota(CurrentBucket, ParsedProps, ClusterStorageTotals, UsageGetter) ->
    ParsedQuota = proplists:get_value(ram_quota, ParsedProps),
    ClusterTotals = proplists:get_value(ram, ClusterStorageTotals),
    OtherBuckets = proplists:get_value(quotaUsed, ClusterTotals)
        - case CurrentBucket of
              [_|_] ->
                  ns_bucket:ram_quota(CurrentBucket);
              _ ->
                  0
          end,
    ThisUsed = case CurrentBucket of
                   [_|_] ->
                       UsageGetter(ram, proplists:get_value(name, ParsedProps));
                   _ -> 0
               end,
    Total = proplists:get_value(quotaTotal, ClusterTotals),
    #ram_summary{total = Total,
                 other_buckets = OtherBuckets,
                 this_alloc = ParsedQuota,
                 this_used = ThisUsed,
                 free = Total - OtherBuckets - ParsedQuota}.

-define(PHDD(K, KO), {KO, V#hdd_summary.K}).
hdd_summary_to_proplist(V) ->
    [?PHDD(total, total),
     ?PHDD(other_data, otherData),
     ?PHDD(other_buckets, otherBuckets),
     ?PHDD(this_alloc, thisAlloc),
     ?PHDD(this_used, thisUsed),
     ?PHDD(free, free)].

interpret_hdd_quota(CurrentBucket, ParsedProps, ClusterStorageTotals, UsageGetter) ->
    ParsedQuota = proplists:get_value(hdd_quota, ParsedProps),
    ClusterTotals = proplists:get_value(hdd, ClusterStorageTotals),
    UsedByUs = UsageGetter(hdd, all),
    ThisUsed = case CurrentBucket of
                   [_|_] ->
                       UsageGetter(hdd, proplists:get_value(name, ParsedProps));
                   _ -> 0
               end,
    OtherData = proplists:get_value(used, ClusterTotals) - UsedByUs,
    OtherBuckets = proplists:get_value(quotaUsed, ClusterTotals)
        - case CurrentBucket of
              [_|_] ->
                  case ns_bucket:hdd_quota(CurrentBucket) of
                      undefined -> 0;
                      X -> X
                  end;
              _ ->
                  0
          end,
    Total = proplists:get_value(total, ClusterTotals),
    #hdd_summary{total = Total,
                 other_data = OtherData,
                 other_buckets = OtherBuckets,
                 this_alloc = ParsedQuota,
                 this_used = ThisUsed,
                 free = Total - OtherData - OtherBuckets - ParsedQuota}.

parse_validate_replicas_number(NumReplicas) ->
    case menelaus_util:parse_validate_number(NumReplicas, 0, undefined) of
        invalid ->
            {error, replicaNumber, <<"Replicas number must be a number">>};
        too_small ->
            {error, replicaNumber, <<"Replicas number cannot be negative">>};
        {ok, X} -> {ok, num_replicas, X}
    end.

parse_validate_ram_quota(Value) ->
    case menelaus_util:parse_validate_number(Value, 0, undefined) of
        invalid ->
            {error, ramQuotaMB, <<"RAM quota must be a number">>};
        too_small ->
            {error, ramQuotaMB, <<"RAM quota cannot be negative">>};
        {ok, X} -> {ok, ram_quota, X * 1048576}
    end.

parse_validate_hdd_quota(Value) ->
    case menelaus_util:parse_validate_number(Value, 0, undefined) of
        invalid ->
            {error, hddQuotaGB, <<"Disk quota must be a number">>};
        too_small ->
            {error, hddQuotaGB, <<"Disk quota cannot be negative">>};
        {ok, X} -> {ok, hdd_quota, X * 1048576 * 1024}
    end.
