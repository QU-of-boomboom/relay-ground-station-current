`timescale 1ns/1ps
// 真实监测到告警与原子快照；未上板，见同名规格。
module gs_alarm_monitor #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000, // 毫秒周期
    parameter [15:0] C_BAD_HOLD=16'd2, // 固定连续坏质量毫秒门限
    parameter [15:0] C_GOOD_HOLD=16'd2 // 固定连续好质量恢复门限
)(
    input i_clk, // 单一时钟
    input i_rst, // 同步复位
    input i_config_valid, // 配置请求
    input [325:0] i_config, // 配置完整载荷
    input i_valid, // 统计证据请求
    input [371:0] i_packet, // 统计证据完整载荷
    output [1:0] o_ready, // 配置ready和证据ready
    output [329:0] o_config_state, // 配置握手及活动配置诊断
    output [65:0] o_clock_state, // now、tick、fault
    output [444:0] o_cache_state, // ready、done、receipt、cache
    output [453:0] o_publication_state, // 代号及完整发布接口
    output o_window, // 关闭窗口事件
    output [794:0] o_window_data, // sequence64/active224/time64/present1/payload442
    output o_alarm_valid, // 当前告警状态可用
    output o_alarm, // 仅valid时解释
    output [2:0] o_alarm_state, // 现有五态告警编码
    output o_snapshot, // 新的原子软件快照事件
    output [799:0] o_snapshot_data, // 窗口795加state3/valid1/alarm1
`ifdef GS_SHARED_QUALITY
    output o_compute_request, // S沿质量重评请求，原样送往共享队列
    output o_compute_cancel, // 本来源复位或缓存变化，撤销旧计算
    output [778:0] o_compute_payload, // 与请求同行的完整原始质量输入
    output [7:0] o_compute_generation, // 与输入同行的本沿新代号
    input i_compute_valid, // 仅本来源的共享返回资格
    input [7:0] i_compute_generation, // 返回结果保留的原请求代号
    input [441:0] i_compute_payload, // 原质量结果，不刷新评估时刻
`endif
    output o_snapshot_clear // 同步撤销PS冻结记录，配置与故障优先
);
    wire cfg_ready,commit,reject,configured,ready,done; // 监测握手
    wire [325:0] config_active; // 生效配置
    wire [63:0] now_ms; // 本地时间
    wire tick,clock_fault,rollover,change,config_clear; // 显式跨模块控制
    wire [3:0] receipt; // 接收结果
    wire [438:0] cache; // 原子缓存
    wire [7:0] generation; // 发布代号
    wire request,schedule_fault,publication,current_valid; // 发布资格
    wire [441:0] payload; // 原质量发布
    wire window_event,window_present,alarm_clear; // 窗口输出
    wire [2:0] window_condition; // 三位业务条件
    wire [63:0] window_sequence,window_ms; // 窗口标签
    wire [223:0] window_active; // 窗口身份
    wire [441:0] window_payload; // 窗口原载荷
    wire [794:0] window_data; // 不可拆分的窗口快照
    wire [1:0] alarm_condition; // 既有告警编码
    wire core_valid,core_alarm; // 告警核心有效性
    wire [2:0] core_state; // 告警核心状态
    reg flag_available; // 缓存更新立即屏蔽旧告警，但保留内部计时
    reg flag_snapshot_pending; // W加一已消费的窗口
`ifndef GS_COMPACT_STORAGE
    reg [794:0] reg_snapshot_window; // 默认实现保留窗口的额外一拍副本
`endif
    wire [794:0] wire_snapshot_window; // W加二沿前仍保持的已关闭窗口
    reg snapshot_o; // W加二快照事件
    reg [799:0] snapshot_data_o; // 原子快照寄存器
    assign o_ready={cfg_ready,ready}; // 单笔接收协议
    assign o_config_state={cfg_ready,commit,reject,configured,config_active}; // 测试及集成诊断
    assign o_clock_state={now_ms,tick,clock_fault}; // 测试及集成诊断
    assign o_cache_state={ready,done,receipt,cache}; // 测试及集成诊断
    assign o_publication_state={generation,request,schedule_fault,publication,current_valid,payload}; // 测试及集成诊断
    assign window_data={window_sequence,window_active,window_ms,window_present,window_payload}; // 原子字段组合
    assign o_window=window_event; // W沿后可见
    assign o_window_data=window_data; // 与事件对齐
    assign alarm_condition=window_condition[2] ? window_condition[1:0] : 2'd0; // 5/6/7映射1/2/3，其余不可用
    assign o_alarm_valid=flag_available & core_valid; // 不可用不解释为正常
    assign o_alarm=flag_available & core_alarm; // 当前资格共同屏蔽
    assign o_alarm_state=flag_available ? core_state : 3'd0; // 对外UNAVAILABLE
    assign o_snapshot=snapshot_o; // W加二之后稳定
    assign o_snapshot_data=snapshot_data_o; // 无事件仍可重复读取同一历史快照
    assign o_snapshot_clear=alarm_clear; // 公开清除契约，不通过测试层次接线
`ifdef GS_COMPACT_STORAGE
    assign wire_snapshot_window=window_data; // P至少23；相邻窗口不能覆盖W加二沿前元数据
`else
    assign wire_snapshot_window=reg_snapshot_window; // 原实现逐位保留，供兼容与等价核对
`endif
    // 清除和缓存变化优先撤销当前可用标志。
    always @(posedge i_clk) begin
        if(alarm_clear | change)flag_available<=1'b0;
        else if(window_event)flag_available<=window_present & window_payload[434];
    end
    // W加一消费窗口，先冻结同一份元数据。
    always @(posedge i_clk) begin
        flag_snapshot_pending<=window_event & (!alarm_clear);
`ifndef GS_COMPACT_STORAGE
        if(window_event)reg_snapshot_window<=window_data;
`endif
    end
    // W加二采样上沿更新后的核心结果，配置清除禁止旧快照发布。
    always @(posedge i_clk) begin
        snapshot_o<=flag_snapshot_pending & (!alarm_clear);
        if(alarm_clear) snapshot_data_o<=800'd0;
        else if(flag_snapshot_pending)snapshot_data_o<={wire_snapshot_window,core_state,core_valid,core_alarm};
    end
    gs_cached_monitor #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS)) Monitor_Inst( // 实际十四模块上游
`ifdef GS_SHARED_QUALITY
        .o_compute_request(o_compute_request),.o_compute_cancel(o_compute_cancel),
        .o_compute_payload(o_compute_payload),.o_compute_generation(o_compute_generation),
        .i_compute_valid(i_compute_valid),.i_compute_generation(i_compute_generation),.i_compute_payload(i_compute_payload),
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_config_valid(i_config_valid),.i_config(i_config),.i_valid(i_valid),.i_packet(i_packet),
        .o_config_ready(cfg_ready),.o_config_commit(commit),.o_config_reject(reject),.o_config(config_active),.o_configured(configured),
        .o_now_ms(now_ms),.o_tick(tick),.o_clock_fault(clock_fault),.o_ready(ready),.o_done(done),.o_receipt(receipt),.o_cache(cache),
        .o_generation(generation),.o_request(request),.o_schedule_fault(schedule_fault),.o_publication(publication),
        .o_current_valid(current_valid),.o_current_payload(payload),.o_rollover(rollover),.o_cache_change(change),.o_alarm_clear(config_clear));
    gs_publication_window Window_Inst( // 只用公开端口，不用层次引用
        .i_clk(i_clk),.i_rst(i_rst),.i_clear(config_clear),.i_fault(clock_fault | schedule_fault),.i_configured(configured),
        .i_active(config_active[325:102]),.i_now_ms(now_ms),.i_rollover(rollover),.i_change(change),.i_generation(generation),
        .i_publication(publication),.i_current_valid(current_valid),.i_payload(payload),.o_clear(alarm_clear),
        .o_window(window_event),.o_present(window_present),.o_condition(window_condition),.o_sequence(window_sequence),
        .o_active(window_active),.o_evaluated_ms(window_ms),.o_payload(window_payload));
    gs_pdr_alarm Alarm_Inst( // 仅使用同步clear复位，异步端固定非有效
        .i_clk(i_clk),.i_rstn(1'b1),.i_clear(alarm_clear),.i_tick_ms(window_event),.i_condition(alarm_condition),
        .i_bad_hold(C_BAD_HOLD),.i_good_hold(C_GOOD_HOLD),.o_state(core_state),.o_valid(core_valid),.o_alarm(core_alarm));
endmodule
