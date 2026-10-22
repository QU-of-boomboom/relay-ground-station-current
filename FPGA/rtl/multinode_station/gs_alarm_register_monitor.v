`timescale 1ns/1ps
// 监测器与PS快照银行的生产同钟接线；物理AXI桥及基地址待板级集成。
module gs_alarm_register_monitor #(
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
    input [31:0] i_wr_addr, // PS本地写偏移
    input [31:0] i_wr_data, // PS全字写数据
    input i_wr_valid, // 写有效
    output o_wr_ready, // 写准入
    input [31:0] i_rd_addr, // PS本地读偏移
    input i_rd_valid, // 读有效
    output o_rd_ready, // 读准入
    output [31:0] o_rd_data, // 注册响应
    output o_rd_valid, // 响应有效
    input i_rd_ready, // 响应消费
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
    gs_alarm_monitor #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_BAD_HOLD(C_BAD_HOLD),.C_GOOD_HOLD(C_GOOD_HOLD)) Monitor_Inst(
`ifdef GS_SHARED_QUALITY
        .o_compute_request(o_compute_request),.o_compute_cancel(o_compute_cancel),
        .o_compute_payload(o_compute_payload),.o_compute_generation(o_compute_generation),
        .i_compute_valid(i_compute_valid),.i_compute_generation(i_compute_generation),.i_compute_payload(i_compute_payload),
`endif
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_config_valid(i_config_valid),
        .i_config(i_config),
        .i_valid(i_valid),
        .i_packet(i_packet),
        .o_ready(o_ready),
        .o_config_state(o_config_state),
        .o_clock_state(o_clock_state),
        .o_cache_state(o_cache_state),
        .o_publication_state(o_publication_state),
        .o_window(o_window),
        .o_window_data(o_window_data),
        .o_alarm_valid(o_alarm_valid),
        .o_alarm(o_alarm),
        .o_alarm_state(o_alarm_state),
        .o_snapshot(o_snapshot),
        .o_snapshot_data(o_snapshot_data),
        .o_snapshot_clear(o_snapshot_clear));
`ifdef GS_COMPACT_STORAGE
    gs_alarm_snapshot_bank_compact Bank_Inst(
`else
    gs_alarm_snapshot_bank Bank_Inst(
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_clear(o_snapshot_clear),.i_snapshot(o_snapshot),.i_payload(o_snapshot_data),
        .i_wr_addr(i_wr_addr),.i_wr_data(i_wr_data),.i_wr_valid(i_wr_valid),.o_wr_ready(o_wr_ready),
        .i_rd_addr(i_rd_addr),.i_rd_valid(i_rd_valid),.o_rd_ready(o_rd_ready),
        .o_rd_data(o_rd_data),.o_rd_valid(o_rd_valid),.i_rd_ready(i_rd_ready));
endmodule
