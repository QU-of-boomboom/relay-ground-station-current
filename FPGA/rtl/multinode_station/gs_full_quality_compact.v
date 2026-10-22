`timescale 1ns / 1ps
// 保留完整质量判定，将最终返回元数据放入固定延迟BRAM旁路。
module gs_full_quality_compact(
    input i_clk, // 唯一时钟
    input i_rst, // 同步高复位
    input i_clear, // 同步撤销所有在途
    input i_valid, // 质量请求资格
    input [8:0] i_count, // 统计总量
    input [8:0] i_delivered, // 送达量
    input [8:0] i_window, // 窗口容量
    input [8:0] i_minimum, // 预热最少数量
    input [9:0] i_low, // 低质量千分比
    input [9:0] i_high, // 恢复千分比
    input [223:0] i_active, // 活动身份及修订
    input [353:0] i_context, // 来源完整上下文
    input [15:0] i_tag, // 诊断标签
    input i_evidence_present, // 证据存在标记
    input [63:0] i_now_ms, // 评估原时刻
    input [63:0] i_max_age_ms, // 来源过期上限
    output o_valid, // 与原核心相同的E加十八沿事件
    output [3:0] o_reason, // 原核心判定原因
    output [2:0] o_condition, // 原核心质量条件
    output o_usable, // 原核心数值资格
    output [15:0] o_tag, // BRAM同行的原诊断标签
    output [353:0] o_context, // BRAM同行的原证据
    output [63:0] o_evaluated_ms // BRAM同行的原评估时间
);
    wire flag_flush; // 两个同步撤销条件
    wire [433:0] reg_payload; // BRAM读取的完整返回载荷
    assign flag_flush=i_rst | i_clear;
    assign o_tag=reg_payload[433:418];
    assign o_context=reg_payload[417:64];
    assign o_evaluated_ms=reg_payload[63:0];
    gs_payload_delay #(.C_WIDTH(434),.C_DELAY(18)) Metadata_Inst(
        .i_clk(i_clk),.i_rst(flag_flush),.i_payload({i_tag,i_context,i_now_ms}),.o_payload(reg_payload));
    gs_full_quality Core_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_clear(i_clear),.i_valid(i_valid),
        .i_count(i_count),.i_delivered(i_delivered),.i_window(i_window),.i_minimum(i_minimum),
        .i_low(i_low),.i_high(i_high),.i_active(i_active),.i_context(i_context),.i_tag(i_tag),
        .i_evidence_present(i_evidence_present),.i_now_ms(i_now_ms),.i_max_age_ms(i_max_age_ms),
        .o_valid(o_valid),.o_reason(o_reason),.o_condition(o_condition),.o_usable(o_usable),
        .o_tag(),.o_context(),.o_evaluated_ms());
endmodule
