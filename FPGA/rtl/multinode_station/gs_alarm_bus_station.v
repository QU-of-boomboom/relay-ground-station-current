`timescale 1ns/1ps
// 全部配置、证据和快照通过本地寄存器；同钟实验子系统，未上板。
module gs_alarm_bus_station #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000,
    parameter [8:0] C_WINDOW=9'd64,
    parameter [15:0] C_BAD_HOLD=16'd2,
    parameter [15:0] C_GOOD_HOLD=16'd2
)(
    input i_clk, // 守卫与业务共同采样时钟
    input i_rst, // 同步整站复位，旧软件会话必须终止
    input i_backend_reset, // 同步仅业务复位，守卫epoch保留
    input [31:0] i_wr_addr, // 子系统局部字节偏移
    input [31:0] i_wr_data, // 全字写数据
    input i_wr_valid, // 写请求
    output o_wr_ready, // 写接受
    input [31:0] i_rd_addr, // 子系统局部字节偏移
    input i_rd_valid, // 读请求
    output o_rd_ready, // 读接受
    output [31:0] o_rd_data, // 守卫保留的读响应
    output o_rd_valid, // 读响应有效
    input i_rd_ready, // 软件消费响应
    output [329:0] o_config_state, // 真实生效配置诊断
    output [65:0] o_clock_state, // 真实毫秒时基
    output [444:0] o_cache_state, // 真实证据缓存
    output [453:0] o_publication_state, // 真实发布
    output [795:0] o_window_state, // 窗口事件与载荷
    output [4:0] o_alarm_state, // 当前有效性及状态
`ifdef GS_SHARED_QUALITY
    output o_compute_request, // S沿质量重评请求，原样送往共享队列
    output o_compute_cancel, // 本来源复位或缓存变化，撤销旧计算
    output [778:0] o_compute_payload, // 与请求同行的完整原始质量输入
    output [7:0] o_compute_generation, // 与输入同行的本沿新代号
    input i_compute_valid, // 仅本来源的共享返回资格
    input [7:0] i_compute_generation, // 返回结果保留的原请求代号
    input [441:0] i_compute_payload, // 原质量结果，不刷新评估时刻
`endif
    output [800:0] o_snapshot_state // 快照事件与载荷
);
    wire backend_reset,backend_up; // 同步撤销和预热后准入
    reg [2:0] reg_warmup; // 业务复位后等待三个完整时钟
    wire [31:0] backend_wa,backend_wd,backend_ra,backend_data; // 守卫后总线
    wire backend_wv,backend_wr,backend_rv,backend_rr,backend_valid,backend_ready; // 后台握手
    wire flag_write_snapshot,flag_write_control,flag_read_snapshot,flag_read_control; // 完整高位地址译码
    wire snapshot_wr,snapshot_rr,snapshot_valid,control_wr,control_rr,control_valid; // 银行响应
    wire [31:0] snapshot_data,control_data; // 银行读数据
    wire config_valid,packet_valid; // 原子输入命令
    wire [325:0] config_data; // 配置载荷
    wire [371:0] packet_data; // 统计载荷
    wire settle_valid,settle_ready,settle_done,evidence_valid; // 硬件窗口桥接握手
    wire [255:0] settle_command,settle_response; // 原统计事务载荷
    wire [31:0] settle_receipt; // 桥与执行器、缓存结果
    wire [371:0] evidence_packet; // 真实硬件计数证据
    wire selected_packet_valid; // 串行控制银行保证两个来源互斥
    wire [371:0] selected_packet; // 与有效资格同行
    wire [1:0] monitor_ready; // 核心准入
    wire window_event,alarm_valid,alarm,snapshot_event,snapshot_clear; // 核心事件
    wire [794:0] window_data; // 窗口内容
    wire [2:0] alarm_state; // 五态编码
    wire [799:0] snapshot_payload; // 原子软件记录
    reg flag_unused_response; // 未映射读的单槽响应
    assign backend_reset=i_rst | i_backend_reset;
    assign backend_up=(!backend_reset) & reg_warmup[2];
    assign flag_write_snapshot=(backend_wa[31:8]==24'd0);
    assign flag_write_control=(backend_wa[31:8]==24'd1);
    assign flag_read_snapshot=(backend_ra[31:8]==24'd0);
    assign flag_read_control=(backend_ra[31:8]==24'd1);
    assign backend_wr=flag_write_snapshot ? snapshot_wr : flag_write_control ? control_wr : !backend_reset;
    assign backend_rr=flag_read_snapshot ? snapshot_rr : flag_read_control ? control_rr : ((!backend_reset) & (!flag_unused_response));
    assign backend_valid=flag_read_snapshot ? snapshot_valid : flag_read_control ? control_valid : flag_unused_response;
    assign backend_data=flag_read_snapshot ? snapshot_data : flag_read_control ? control_data : 32'h47534e41;
    assign o_window_state={window_event,window_data};
    assign o_alarm_state={alarm_valid,alarm,alarm_state};
    assign o_snapshot_state={snapshot_event,snapshot_payload};
    assign selected_packet_valid=packet_valid | evidence_valid;
    assign selected_packet=evidence_valid ? evidence_packet : packet_data;
    // 不跨时钟、不异步释放；真实板级接线必须另做CDC与复位方案。
    always @(posedge i_clk) begin
        if(backend_reset)reg_warmup<=3'd0;
        else reg_warmup<={reg_warmup[1:0],1'b1};
    end
    // 未映射写无副作用，未映射读返回GSNA并保持到消费。
    always @(posedge i_clk) begin
        if(backend_reset)flag_unused_response<=1'b0;
        else if(backend_rv & backend_rr & (!flag_read_snapshot) & (!flag_read_control))flag_unused_response<=1'b1;
        else if(backend_ready)flag_unused_response<=1'b0;
    end
    gs_transport_guard Guard_Inst(
        .clk(i_clk),.rst(i_rst),.backend_up(backend_up),
        .wr_addr(i_wr_addr),.wr_data(i_wr_data),.wr_valid(i_wr_valid),.wr_ready(o_wr_ready),
        .rd_addr(i_rd_addr),.rd_valid(i_rd_valid),.rd_ready(o_rd_ready),
        .rd_data(o_rd_data),.rd_data_valid(o_rd_valid),.rd_data_ready(i_rd_ready),
        .backend_wr_addr(backend_wa),.backend_wr_data(backend_wd),.backend_wr_valid(backend_wv),.backend_wr_ready(backend_wr),
        .backend_rd_addr(backend_ra),.backend_rd_valid(backend_rv),.backend_rd_ready(backend_rr),
        .backend_rd_data(backend_data),.backend_rd_data_valid(backend_valid),.backend_rd_data_ready(backend_ready));
`ifdef GS_FROZEN_CONTROL
    gs_monitor_control_bank_compact Control_Inst(
`else
    gs_monitor_control_bank Control_Inst(
`endif
        .i_clk(i_clk),.i_rst(backend_reset),.i_wr_addr({24'd0,backend_wa[7:0]}),.i_wr_data(backend_wd),
        .i_wr_valid(backend_wv & flag_write_control),.o_wr_ready(control_wr),
        .i_rd_addr({24'd0,backend_ra[7:0]}),.i_rd_valid(backend_rv & flag_read_control),.o_rd_ready(control_rr),
        .o_rd_data(control_data),.o_rd_valid(control_valid),.i_rd_ready(backend_ready & flag_read_control),
        .o_config_valid(config_valid),.o_config(config_data),.i_config_ready(monitor_ready[1]),
        .i_config_commit(o_config_state[328]),.i_config_reject(o_config_state[327]),
        .o_packet_valid(packet_valid),.o_packet(packet_data),.i_packet_ready(monitor_ready[0]),
        .i_packet_done(o_cache_state[443]),.i_receipt(o_cache_state[442:439]),
        .o_settle_valid(settle_valid),.o_settle(settle_command),.i_settle_ready(settle_ready),.i_settle_done(settle_done),
        .i_settle_receipt(settle_receipt),.i_settle_response(settle_response));
`ifdef GS_FROZEN_EVIDENCE
    gs_pdr_evidence_executor_compact #(.C_WINDOW(C_WINDOW)) Evidence_Inst(
`else
    gs_pdr_evidence_executor #(.C_WINDOW(C_WINDOW)) Evidence_Inst(
`endif
        .i_clk(i_clk),.i_rst(backend_reset),.i_valid(settle_valid),.i_command(settle_command),.o_ready(settle_ready),
        .i_configured(o_config_state[326]),.i_active(o_config_state[325:102]),.i_window(o_config_state[101:93]),.i_now_ms(o_clock_state[65:2]),
        .o_done(settle_done),.o_receipt(settle_receipt),.o_response(settle_response),.o_packet_valid(evidence_valid),.o_packet(evidence_packet),
        .i_packet_ready(monitor_ready[0]),.i_packet_done(o_cache_state[443]),.i_packet_receipt(o_cache_state[442:439]));
    gs_alarm_register_monitor #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_BAD_HOLD(C_BAD_HOLD),.C_GOOD_HOLD(C_GOOD_HOLD)) Monitor_Inst(
`ifdef GS_SHARED_QUALITY
        .o_compute_request(o_compute_request),.o_compute_cancel(o_compute_cancel),
        .o_compute_payload(o_compute_payload),.o_compute_generation(o_compute_generation),
        .i_compute_valid(i_compute_valid),.i_compute_generation(i_compute_generation),.i_compute_payload(i_compute_payload),
`endif
        .i_clk(i_clk),.i_rst(backend_reset),.i_config_valid(config_valid),.i_config(config_data),
        .i_valid(selected_packet_valid),.i_packet(selected_packet),.o_ready(monitor_ready),
        .o_config_state(o_config_state),.o_clock_state(o_clock_state),.o_cache_state(o_cache_state),.o_publication_state(o_publication_state),
        .o_window(window_event),.o_window_data(window_data),.o_alarm_valid(alarm_valid),.o_alarm(alarm),.o_alarm_state(alarm_state),
        .o_snapshot(snapshot_event),.o_snapshot_data(snapshot_payload),.o_snapshot_clear(snapshot_clear),
        .i_wr_addr({24'd0,backend_wa[7:0]}),.i_wr_data(backend_wd),.i_wr_valid(backend_wv & flag_write_snapshot),.o_wr_ready(snapshot_wr),
        .i_rd_addr({24'd0,backend_ra[7:0]}),.i_rd_valid(backend_rv & flag_read_snapshot),.o_rd_ready(snapshot_rr),
        .o_rd_data(snapshot_data),.o_rd_valid(snapshot_valid),.i_rd_ready(backend_ready & flag_read_snapshot));
endmodule
