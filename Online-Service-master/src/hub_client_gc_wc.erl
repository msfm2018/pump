%% coding: utf-8
-module(hub_client_gc_wc).
-include("common.hrl").
-include("proto_player.hrl").

-export([loop/2]).
-export([receive_data/3]).
-export([handle_other/3]).


format_current_datetime() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:local_time(),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
                  [Year, Month, Day, Hour, Minute, Second]).


loop(Socket, {connected}) ->

    case inet:peername(Socket) of
        {ok, {Ip, Port}} ->
            DateTimeStr = format_current_datetime(),
            IpStr = inet:ntoa(Ip),
            LogMsg = io_lib:format("~s - IP: ~s, Port: ~w",
                                   [DateTimeStr, IpStr, Port]),
            io:format("连接：：~s~n", [LogMsg]);
        {error, einval} ->
            io:format("Socket invalid  ~n");
        {error, Other} ->
            io:format("Unknown error in peername: ~p~n", [Other])
    end,
    ok;

loop(Socket, {terminate, Reason}) ->
    case inet:peername(Socket) of
        {ok, {Ip, Port}} ->
            DateTimeStr = format_current_datetime(),
            IpStr = inet:ntoa(Ip),
            LogMsg = io_lib:format("~s - IP: ~s, Port: ~w, Terminate Reason: ~p",
                                   [DateTimeStr, IpStr, Port, Reason]),
            io:format("终止：：~s~n", [LogMsg]);
        {error, einval} ->
            io:format("Socket invalid when terminating: ~p~n", [Reason]);
        {error, Other} ->
            io:format("Unknown error in peername: ~p~n", [Other])
    end,
    ok;

loop(_Socket, <<>>) ->
    % 忽略空数据，通常是 TCP 流的末尾或不完整的数据包
    ok;

loop(Socket, {timeout, first_data}) ->
    io:format("Initial data timeout for socket ~p. Closing connection.~n", [Socket]),
    ok;

loop(Socket, {timeout, heartbeat}) ->
    case inet:peername(Socket) of
        {ok, {Ip, Port}} ->
            IpStr = inet:ntoa(Ip),
            DateTimeStr = format_current_datetime(),
            LogMsg = io_lib:format("~s - IP: ~s, Port: ~w, Heartbeat Timeout ~n",
                                   [DateTimeStr, IpStr, Port]),
            io:format("超时：：~s~n", [LogMsg]),
            ok;
        {error, Reason} ->
            DateTimeStr = format_current_datetime(),
            LogMsg = io_lib:format("~s - Unknown peer (heartbeat timeout), reason: ~p~n",
                                   [DateTimeStr, Reason]),
            io:format("~s~n", [LogMsg]),
            ok
    end;

loop(_Socket, {turn_off_alarm, Id}) ->
    case ets:lookup(socket_map, Id) of
        [{Id, Map}] ->
            Socket1 = maps:get(socket, Map, undefined),
            gen_tcp:send(Socket1, <<"ledoff\r\n">>),
            NewMap = maps:put(alarm_light, off, Map),
            ets:insert(socket_map, {Id, NewMap}),
            io:format("定时熄灭设备 ~p 的报警灯~n", [Id]);
        _ ->
            io:format("报警灯关闭失败：未找到设备 ~p~n", [Id])
    end,
    ok;

loop(Socket, Data) ->
    try
        case proto:handle(Data) of
            % 心跳
            {client_request, mod_player, #mod_player_herat_c2s{}} ->
                gen_tcp:send(Socket, <<"ack\r\n">>),
                gen_server:cast(self(), reset_timeout),
                ok;

            % 注册id
            {client_request, mod_player, #mod_player_login_c2s{id = Id, token = _Token}} ->

                % --- 新增逻辑：检查并关闭旧连接 ---
                case ets:lookup(socket_map, Id) of
                    [{Id, Map}] ->
                        OldSocket = maps:get(socket, Map, undefined),
                        OldPid = maps:get(pid, Map, undefined),  % <-- 获取旧进程的PID

                        if
                            is_pid(OldPid) ->
                                % 向旧进程发送 cast 消息，让它自己优雅地终止
                                gen_server:cast(OldPid, {shutdown, new_login}),
                                io:format("通知旧进程终止：设备ID=~p, 旧Socket=~p, 旧PID=~p~n", [Id, OldSocket, OldPid]);
                            true ->
                                % 如果没有 PID，说明记录有问题，直接关闭 Socket
                                catch gen_tcp:close(OldSocket),
                                io:format("旧进程信息缺失，直接关闭 Socket：设备ID=~p, 旧Socket=~p~n", [Id, OldSocket])
                        end;
                    _ ->
                        ok
                end,
                % ---------------------------------

                register_device(Id, Socket),
                gen_tcp:send(Socket, <<"oklogin\r\n">>),
                 gen_server:cast(self(), reset_timeout),
                io:format("Device login successful: ID=~p ~p ~n", [Id, Socket]),

                case ets:lookup(sensor_alarm_config, thresholds) of
                    [{thresholds, Conf}] ->
                        HumHigh = maps:get(hum_high, Conf, 3000),
                        HumLow = maps:get(hum_low, Conf, 2000),

                        ThresholdMsg = io_lib:format("hum_high=~p&hum_low=~p\r\n", [HumHigh, HumLow]),
                        case gen_tcp:send(Socket, list_to_binary(ThresholdMsg)) of
                            ok ->
                                io:format("命令已发送: ~s~n", [ThresholdMsg]);
                            A ->
                                io:format("发送失败: ~p~n", [A])
                        end,

                        io:format("下发阈值给设备 ~p -> hum_high=~p, hum_low=~p~n", [Id, HumHigh, HumLow]);
                    [] ->
                        io:format("未配置阈值，设备 ~p 使用默认参数~n", [Id])
                end,

                ok;

            %  温湿度
            {client_request, mod_player, #mod_device_data_c2s{id = Id, temperature = T, humidity = H}} ->
                io:format("收到温湿度: ID=~p, T=~p, H=~p~n", [Id, T, H]),
                New = #{id => Id, temperature => T, humidity => H},
                ets:insert(sensor_latest, {Id, New}),

                % 存历史数据到 Mnesia
                HistoryRec = #sensor_history{
                               id = Id,
                               timestamp = os:system_time(second),
                               temperature = T,
                               humidity = H
                              },
                ok = mnesia:dirty_write(HistoryRec),

                gen_server:cast(self(), reset_timeout),
                ok;

            Other ->
                io:format("Unknown message: ~p~n", [Other])
        end

    catch
        _:Reason ->
            io:format("Error parsing data: ~p~n", [Reason]),
            receive_data(Socket, <<"raw">>, Data)

    end.


register_device(DeviceId, Socket) ->
    ets:insert(socket_map, {DeviceId, #{socket => Socket, pid => self(), alarm_light => off}}).


%%%-----------------------------------------------------------------
%%% 尚未实现的其它业务类型
%%%-----------------------------------------------------------------
handle_other(_Socket, Type, Map) ->
    io:format("Unhandled type: ~p, payload: ~p~n", [Type, Map]),
    ok.


%%%-----------------------------------------------------------------
%%% 具体数据处理
%%%-----------------------------------------------------------------


receive_data(_Socket, <<"raw">>, Raw) ->
    io:format("无法解析的数据: ~p~n", [Raw]).
