%% 文件: pump_handler.erl
-module(pump_handler).
-export([init/2]).

-define(JSON_HEADER, #{<<"content-type">> => <<"application/json">>}).


init(Req0=#{method := <<"POST">>}, State) ->

io:format("~p~n",[{Req0}]),


    %% 支持跨域
    Req1 = allow_cors(Req0),

    #{bindings := #{action := ActionBin, id := IdBin}} = Req1,

  
        
          


    Action = binary_to_atom(ActionBin, utf8),
    Id     = binary_to_integer(IdBin),

    io:format("接收到水泵控制请求: 动作=~p, ID=~p~n", [Action, Id]),

    %% 在这里写你的业务逻辑，比如查找设备 socket 然后发控制命令


    Result = control_pump(Action, Id),

    %% 构造返回
    RespJson = case Result of
        ok ->
            json:encode(#{code => 0, msg => <<"pump control success">>});
        {error, Reason} ->
            json:encode(#{code => 1, msg => Reason})
    end,

    {ok, Resp} = cowboy_req:reply(200, ?JSON_HEADER, RespJson, Req1),
    {ok, Resp, State}.

%% 跨域支持
allow_cors(Req) ->
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, <<"*">>, Req),
    Req2 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, POST, OPTIONS">>, Req1),
    cowboy_req:set_resp_header(<<"access-control-allow-headers">>, <<"content-type">>, Req2).

%% 实际业务逻辑
control_pump(on, Id) ->
    case ets:lookup(socket_map, Id) of
        [{_, Map}] ->
            Socket = maps:get(socket, Map, undefined),
            case Socket of
                undefined ->
                    {error, <<"socket not found">>};
                _ ->
                    ok = gen_tcp:send(Socket, <<"pump_on\r\n">>),
                    io:format("水泵已开启, ID=~p~n", [Id]),
                    ok
            end;
        [] ->
            {error, <<"device not found">>}
    end;

control_pump(off, Id) ->
    case ets:lookup(socket_map, Id) of
        [{_, Map}] ->
            Socket = maps:get(socket, Map, undefined),
            case Socket of
                undefined ->
                    {error, <<"socket not found">>};
                _ ->
                    ok = gen_tcp:send(Socket, <<"pump_off\r\n">>),
                    io:format("水泵已关闭, ID=~p~n", [Id]),
                    ok
            end;
        [] ->
            {error, <<"device not found">>}
    end.
