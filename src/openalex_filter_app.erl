%%%-------------------------------------------------------------------
%%% @doc OpenAlex scholarly-works agent (api.openalex.org, open, no key).
%%% No mailto is sent (privacy). Handler: handle/2 -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(openalex_filter_app).
-export([handle/2, base_capabilities/0]).
-define(TTL, 300).
-define(UA, "Mozilla/5.0 (X11; Linux aarch64; rv:128.0) Gecko/20100101 Firefox/128.0").

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"science">>, <<"research">>, <<"papers">>, <<"academic">>, <<"machine">>, <<"learning">>, <<"ai">>, <<"deep">>, <<"neural">>, <<"algorithm">>, <<"physics">>, <<"biology">>, <<"chemistry">>, <<"medicine">>, <<"study">>, <<"model">>, <<"quantum">>, <<"climate">>, <<"genetics">>].

handle(Body, Memory) when is_binary(Body) ->
    Q = extract_value(Body),
    Mem0 = case Memory of M when is_map(M) -> M; _ -> #{} end,
    Cache = maps:get(cache, Mem0, #{}),
    Now = erlang:system_time(second),
    case maps:get(Q, Cache, undefined) of
        {Ts, Res} when (Now - Ts) =< ?TTL -> {Res, Mem0};
        _ -> Res = gen(Q), {Res, Mem0#{cache => Cache#{Q => {Now, Res}}}}
    end;
handle(_Body, Memory) -> {[], Memory}.

gen("") -> [];
gen(Q) ->
    Url = "https://api.openalex.org/works?search=" ++
          uri_string:quote(Q) ++ "&per-page=25",
    case fetch_json(Url, 12) of
        {ok, #{<<"results">> := Rs}} when is_list(Rs) ->
            [emb(R) || R <- Rs];
        _ -> []
    end.

emb(R) ->
    Title = case maps:get(<<"title">>, R, null) of
                null -> <<"(untitled)">>;
                T    -> to_b(T)
            end,
    Year  = maps:get(<<"publication_year">>, R, null),
    Url   = work_url(R),
    Auth  = first_author(R),
    #{<<"properties">> => #{
        <<"url">>    => Url,
        <<"title">>  => Title,
        <<"resume">> => fmt("~ts~ts", [year_str(Year), Auth])}}.

work_url(R) ->
    case maps:get(<<"doi">>, R, null) of
        D when is_binary(D) -> D;  %% already a full https://doi.org/... URL
        _ ->
            case maps:get(<<"primary_location">>, R, #{}) of
                #{<<"landing_page_url">> := L} when is_binary(L) -> L;
                _ -> to_b(maps:get(<<"id">>, R, <<>>))
            end
    end.

first_author(R) ->
    case maps:get(<<"authorships">>, R, []) of
        [#{<<"author">> := #{<<"display_name">> := N}} | _] when is_binary(N) ->
            <<" - ", N/binary>>;
        _ -> <<>>
    end.

year_str(Y) when is_integer(Y) -> integer_to_binary(Y);
year_str(_) -> <<"n/a">>.

extract_value(Body) ->
    try json:decode(Body) of
        M when is_map(M) ->
            binary_to_list(maps:get(<<"value">>, M, maps:get(<<"query">>, M, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

fetch_json(Url, T) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    case httpc:request(get, {Url, [{"User-Agent", ?UA}, {"Accept", "application/json"}]},
                       [{timeout, T * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, B}} -> try {ok, json:decode(B)} catch _:_ -> {error, badjson} end;
        {ok, {{_, C, _}, _, _}}   -> {error, {http, C}};
        {error, R}                -> {error, R}
    end.

to_b(B) when is_binary(B) -> B;
to_b(L) when is_list(L)   -> list_to_binary(L);
to_b(_)                   -> <<>>.
fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
