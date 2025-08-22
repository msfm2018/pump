%% coding: utf-8
-module(hub_client_gc_wc).
-include("common.hrl").
-include("proto_player.hrl").

-export([loop/2]).
-export([receive_data/3]).
-export([ handle_other/3]).

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
            io:format("~s~n", [LogMsg]);
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
            io:format("~s~n", [LogMsg]);
        {error, einval} ->
                io:format("Socket invalid when terminating: ~p~n", [Reason]);
        {error, Other} ->
                io:format("Unknown error in peername: ~p~n", [Other])
    end,
    ok;

loop(_Socket, <<>>) ->
    % 忽略空数据，通常是 TCP 流的末尾或不完整的数据包
  ok;

loop(Socket,  {timeout, first_data}) ->
  io:format("Initial data timeout for socket ~p. Closing connection.~n", [Socket]),
  ok;


loop(Socket, {timeout, heartbeat}) ->
    case inet:peername(Socket) of
        {ok, {Ip, Port}} ->
            IpStr = inet:ntoa(Ip),
            DateTimeStr = format_current_datetime(),
            LogMsg = io_lib:format("~s - IP: ~s, Port: ~w, Heartbeat Timeout ~n",
                                   [DateTimeStr, IpStr, Port]),
            io:format("~s~n", [LogMsg]),
            ok;
        {error, Reason} ->
            DateTimeStr = format_current_datetime(),
            LogMsg = io_lib:format("~s - Unknown peer (heartbeat timeout), reason: ~p~n",
                                   [DateTimeStr, Reason]),
            io:format("~s~n", [LogMsg]),
            ok
    end;



  loop(Socket, Data) ->
    try
        case proto:handle(Data) of
            % 心跳
            {client_request, mod_player, #mod_player_herat_c2s{}} ->  
                gen_tcp:send(Socket, <<"{\"type\":\"ack\"}\r\n">>),
                gen_server:cast(self(), reset_timeout),
                ok;

            % 注册id
            {client_request, mod_player, #mod_player_login_c2s{id = Id, token = _Token}}->
                % ets:insert(socket_map, {Id, #{socket => Socket, alarm_light => off}}).
                register_device(Id,Socket),
                gen_tcp:send(Socket, <<"oklogin\r\n">>),
                gen_server:cast(self(), reset_timeout),
                io:format("Device login successful: ID=~p ~p ~n", [Id,Socket]),
                ok;

            %  温湿度   
            {client_request, mod_player, #mod_device_data_c2s{id = Id, temperature=T,humidity=H}}->
                io:format("温湿度: ID=~p, T=~p, H=~p~n", [Id, T, H]),
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

%% 读取阈值配置
case ets:lookup(sensor_alarm_config, thresholds) of
    [{thresholds, Conf}] ->
        %% 温湿度值为二进制字符串，需转为 float
    FloatH = binary_to_float(H),  %% 把二进制湿度转 float
    HumHigh = maps:get(hum_high, Conf, 3000),
    HumLow  = maps:get(hum_low, Conf, 2000),
    io:format("阈值HumLow HumHigh FloatH : ~p -> ~p,~p, ~n", [HumLow, HumHigh, FloatH]),
    case ets:lookup(socket_map, Id) of
        [{_, Map}] ->
            Socket = maps:get(socket, Map, undefined),
            PrevStatus = maps:get(pump_status, Map, off),
    
            CurrStatus = 
                if FloatH > HumHigh -> on;
                   FloatH < HumLow  -> off;
                   true -> PrevStatus
                end,
                io:format("CurrStatus : ~p  ~n", [CurrStatus]),
            %% 状态有变化才发指令
            if CurrStatus =/= PrevStatus ->
               
                Command = case CurrStatus of
                    on  -> <<"pump_on\r\n">>;
                    off -> <<"pump_off\r\n">>
                end, io:format("要变更 ~p ~n",[Command]),
                gen_tcp:send(Socket, Command),
                NewMap = maps:put(pump_status, CurrStatus, Map),
                ets:insert(socket_map, {Id, NewMap}),
                io:format("水泵状态变更: ~p -> ~p, ID=~p, 湿度=~p~n", [PrevStatus, CurrStatus, Id, FloatH]);
            true ->  io:format("no变更  ~n"),
                ok
            end;
        [] ->
            io:format("未找到设备 ~p 的 socket~n", [Id])
    end;
    

        % FloatH = binary_to_float(H),

        % HumHigh  = maps:get(hum_high, Conf, 3000),
 
        % HumLow   = maps:get(hum_low,Conf, 1000),

        % %% 检查是否超限
        % IsHumAlarm  = (FloatH > HumHigh) ,
        % AlarmNeeded = IsHumAlarm,

        % case ets:lookup(socket_map, Id) of
        %     [{Id, Map}] ->
        %         Socket = maps:get(socket, Map, undefined),
        %         PrevStatus = maps:get(alarm_light, Map, off),
        %         CurrStatus = if AlarmNeeded -> on; true -> off end,

        %         case PrevStatus =/= CurrStatus of
        %             true ->
        %                 %% 根据阈值决定开关闸门
        %                 Command = if 
        %                               FloatH > HumHigh -> <<"pump_on\r\n">>;  % 打开阀门放水
        %                               FloatH < HumLow  -> <<"pump_off\r\n">>; %关闭阀门
        %                               true -> <<"">>   %% 在正常范围内不发指令
        %                           end,

        %                 %% 仅当 Command 非空时才发送
        %                 case Command of
        %                     <<>> -> ok;
        %                     _ ->
        %                          gen_tcp:send(Socket, Command),
        %                         io:format("状态变更: ~p -> ~p, 湿度=~p, 阈值=[~p, ~p], 发送指令 ~p~n",
        %                                   [PrevStatus, CurrStatus, FloatH, HumLow, HumHigh, Command])
        %                 end,

        %                 NewMap = maps:put(alarm_light, CurrStatus, Map),
        %                 ets:insert(socket_map, {Id, NewMap});
        %             false ->
        %                 %% 状态没变，不重复发指令
        %                 ok
        %         end;
        %     _ ->
        %         io:format("未找到设备 ~p 的 socket~n", [Id])
        % end;

    _ ->
        io:format("未找到报警阈值配置，跳过检测~n")
end,




                gen_server:cast(self(), reset_timeout),
                ok;

            Other ->
                io:format("Unknown message: ~p~n", [Other])
            end
      
    catch
        _:Reason ->
            io:format("Error parsing data: ~p~n", [Reason]),
            receive_data(Socket, <<"raw">>, Data)

        % _ ->
            % receive_data(Socket, <<"raw">>, Data)
    end;
    loop(Socket, {turn_off_alarm, Id}) ->
        io:format("定时熄灭设4444444444444444备 ~p 的报警灯~n", [Id]),
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
    
    loop(_Socket, UnexpectedMsg) ->
        logger:warning("Received unexpected message in loop: ~p", [UnexpectedMsg]),
        ok.

    register_device(DeviceId, Socket) ->
        ets:insert(socket_map, {DeviceId, #{socket => Socket, alarm_light => off}}).
          
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