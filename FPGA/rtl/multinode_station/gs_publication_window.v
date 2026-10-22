`timescale 1ns/1ps
// 已资格化发布的毫秒收集器，严格沿前采样；见同名规格。
module gs_publication_window(
    input i_clk, // 唯一时钟
    input i_rst, // 同步高有效复位
    input i_clear, // 配置准备或应用清除
    input i_fault, // 时基或发布调度故障
    input i_configured, // 活动配置存在
    input [223:0] i_active, // 当前身份及修订
    input [63:0] i_now_ms, // 当前未关闭毫秒
    input i_rollover, // 本沿先采样后关闭窗口
    input i_change, // 缓存变化撤销旧候选
    input [7:0] i_generation, // 当前发布代号
    input i_publication, // 新发布事件
    input i_current_valid, // 当前发布可消费
    input [441:0] i_payload, // 上游已资格化载荷
    output o_clear, // 同步撤销告警内部状态
    output o_window, // 关闭结果，下一沿供告警消费
    output o_present, // 本窗口有有效发布样本
    output [2:0] o_condition, // 无样本时UPDATE_FAILED
    output [63:0] o_sequence, // 每次关闭增一，复位归零
    output [223:0] o_active, // 本窗口活动配置
    output [63:0] o_evaluated_ms, // 已关闭的毫秒
    output [441:0] o_payload // 无样本时清零
);
    reg [223:0] reg_previous_active; // 检查身份和修订切换
    reg [63:0] reg_blocked_ms; // 清除所在毫秒
    reg flag_blocked; // 禁止当前毫秒恢复
    reg flag_pending; // 本窗口已有候选
    reg [441:0] reg_pending_payload; // 完整原始候选
    reg [7:0] reg_pending_generation; // 候选代号
    reg [63:0] reg_pending_ms; // 候选窗口归属
    reg window_o,present_o; // 关闭及样本资格
    reg [63:0] sequence_o,evaluated_ms_o; // 软件快照时序标签
    reg [223:0] active_o; // 关闭时身份
    reg [441:0] payload_o; // 关闭原载荷
    wire flag_clear,flag_inhibit,flag_live,flag_accept,flag_selected; // 同沿决策
    wire [441:0] wire_selected; // 新发布优先于已存候选
    (* keep = "true" *) wire [13:0] flag_active_difference; // 保留十四个16位比较端点，避免224位串联进位归约
    genvar gen_identity_chunk; // 固定宽度的身份片段索引
    generate
        for(gen_identity_chunk=0;gen_identity_chunk<14;gen_identity_chunk=gen_identity_chunk+1) begin:gen_active_compare
            assign flag_active_difference[gen_identity_chunk]=
                (i_active[gen_identity_chunk*16 +:16]!=reg_previous_active[gen_identity_chunk*16 +:16]); // 各片段并行比较
        end
    endgenerate
    assign flag_clear=i_rst | i_clear | i_fault | (!i_configured) | (|flag_active_difference); // 故障配置优先，位宽和同沿语义不变
    assign flag_inhibit=flag_clear | (flag_blocked & (reg_blocked_ms==i_now_ms)); // 禁止同毫秒复活
    assign flag_live=flag_pending & i_current_valid & (!i_change) & (reg_pending_generation==i_generation) & (reg_pending_ms==i_now_ms); // 旧候选仍属当前窗口
    assign flag_accept=i_publication & i_current_valid & (!i_change) & (!flag_inhibit); // 保持不是新事件
    assign flag_selected=(!flag_inhibit) & (flag_accept | flag_live); // 清除优先于末沿候选
    assign wire_selected=flag_accept ? i_payload : reg_pending_payload; // 末沿新发布可以立即参与关闭
    assign o_clear=flag_clear; // 供同步告警核心采样
    assign o_window=window_o; // 完整结果下一沿消费
    assign o_present=present_o; // 不可用质量仍可存在合法发布
    assign o_condition=present_o ? payload_o[437:435] : 3'd1; // 不重算上游质量
    assign o_sequence=sequence_o; // 与关闭结果同行
    assign o_active=active_o; // 与关闭结果同行
    assign o_evaluated_ms=evaluated_ms_o; // 与关闭结果同行
    assign o_payload=payload_o; // 保留来源时间及所有上下文
    // 配置比较基准只使用上一沿，复位清基准。
    always @(posedge i_clk) begin
        if(i_rst)reg_previous_active<=224'd0;
        else reg_previous_active<=i_active;
    end
    // 故障/配置清除锁住本毫秒，正常时间推进解除。
    always @(posedge i_clk) begin
        if(flag_clear)begin flag_blocked<=1'b1;reg_blocked_ms<=i_now_ms;end
        else if(reg_blocked_ms!=i_now_ms)flag_blocked<=1'b0;
    end
    // 缓存更新仅撤销候选；不抹除下游驻留计时。
    always @(posedge i_clk) begin
        if(flag_clear | i_rollover)flag_pending<=1'b0;
        else if(flag_accept)flag_pending<=1'b1;
        else if(!flag_live)flag_pending<=1'b0;
    end
    // 候选全部字段一起冻结，禁止刷新原来源时间。
    always @(posedge i_clk) begin
        if(flag_accept)begin
            reg_pending_payload<=i_payload;
            reg_pending_generation<=i_generation;
            reg_pending_ms<=i_now_ms;
        end
    end
    // W关闭沿登记结果，复位不产生关闭事件。
    always @(posedge i_clk) begin
        window_o<=i_rollover & (!i_rst);
        if(i_rst)begin
            sequence_o<=64'd0;present_o<=1'b0;active_o<=224'd0;evaluated_ms_o<=64'd0;payload_o<=442'd0;
        end else if(i_rollover)begin
            sequence_o<=sequence_o+64'd1;
            present_o<=flag_selected;
            active_o<=i_configured ? i_active : 224'd0;
            evaluated_ms_o<=i_now_ms;
            payload_o<=flag_selected ? wire_selected : 442'd0;
        end
    end
endmodule
