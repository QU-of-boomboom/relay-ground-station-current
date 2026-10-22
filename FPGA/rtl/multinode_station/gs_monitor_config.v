`timescale 1ns/1ps
// 同域配置校验与原子提交；规格见gs_monitor_config_spec.md。
module gs_monitor_config #(parameter C_DELAY_ACTIVE=0)(
    
    input i_clk,
    input i_rst, // 同步高有效复位
    
    input i_valid,
    input [325:0] i_config, // 仅ready时冻结完整候选
    
    input [63:0] i_now_ms, // 生效毫秒的硬件时基
    
    output o_ready,
    output o_commit,
    output o_reject, // C加五登记提交或拒绝
    
    output o_configured,
    output o_inhibit, // 初始及同毫秒禁止
    
    output [325:0] o_active // 已应用配置，C加六更新
);
    reg [5:0] reg_pipeline; // 校验到应用令牌
    reg [325:0] reg_candidate; // 候选配置冻结
    reg [63:0] reg_revision; // 接收沿旧修订
    reg [325:0] active_o; // 完整已应用配置
    reg configured_o,commit_o,reject_o; // 配置控制有效性
    reg flag_active_apply; // 可选闭环对齐应用令牌
    reg [63:0] reg_commit_ms; // 当前配置生效毫秒
    wire flag_accept; // 单在途准入
    reg flag_node,flag_session,flag_epoch,flag_revision; // 身份及修订非法
    reg flag_window_zero,flag_window_large,flag_min_zero,flag_min_large; // 窗口规则
    reg flag_low,flag_high,flag_order; // 阈值规则
    reg flag_age_zero,flag_age_sign; // 时间范围规则
    reg flag_identity_bad,flag_window_bad,flag_threshold_bad,flag_age_bad; // 首层分组
    reg flag_high_bad,flag_low_bad,flag_bad; // 两层合并结果
    assign o_ready=(reg_pipeline==6'd0); // 应用沿后才能接受下一笔
    assign flag_accept=i_valid & o_ready; // 复位仍优先清令牌
    assign o_commit=commit_o; // 下一个采样沿应用
    assign o_reject=reject_o; // 拒绝不改变活动配置
    assign o_active=active_o; // 原子配置字段
    assign o_configured=configured_o; // 初始禁用
    assign o_inhibit=({configured_o,(reg_commit_ms==i_now_ms)} != 2'b10); // 保持整个提交毫秒禁止
    // 复位取消全部配置在途。
    always @(posedge i_clk) begin
        if(i_rst)reg_pipeline<=6'd0;
        else reg_pipeline<={reg_pipeline[4:0],flag_accept};
    end
    // 候选字段只在接收沿变化。
    always @(posedge i_clk) begin
        if(flag_accept)reg_candidate<=i_config;
    end
    // 严格递增针对接收时已生效的修订。
    always @(posedge i_clk) begin
        if(flag_accept)begin
            if((C_DELAY_ACTIVE==1) && flag_active_apply)reg_revision<=reg_candidate[165:102];
            else reg_revision<=active_o[165:102];
        end
    end
    // 延迟模式的候选在下一请求接收沿仍为旧Q，允许原子应用与重入同沿。
    always @(posedge i_clk) begin
        if(i_rst)flag_active_apply<=1'b0;
        else flag_active_apply<=commit_o;
    end
    // 下面独立比较在C加一登记。
    always @(posedge i_clk)flag_node<=(reg_candidate[325:294]==32'd0);
    // 会话零保留。
    always @(posedge i_clk)flag_session<=(reg_candidate[293:230]==64'd0);
    // 启动周期零保留。
    always @(posedge i_clk)flag_epoch<=(reg_candidate[229:166]==64'd0);
    // 修订不得重复或倒退。
    always @(posedge i_clk)flag_revision<=(reg_candidate[165:102]<=reg_revision);
    // 窗口必须非零。
    always @(posedge i_clk)flag_window_zero<=(reg_candidate[101:93]==9'd0);
    // 窗口不能超过统计容量。
    always @(posedge i_clk)flag_window_large<=(reg_candidate[101:93]>9'd256);
    // 预热门限必须非零。
    always @(posedge i_clk)flag_min_zero<=(reg_candidate[92:84]==9'd0);
    // 预热门限不得超过窗口。
    always @(posedge i_clk)flag_min_large<=(reg_candidate[92:84]>reg_candidate[101:93]);
    // 低阈值不能为千分之一千。
    always @(posedge i_clk)flag_low<=(reg_candidate[83:74]>10'd999);
    // 高阈值上限一千。
    always @(posedge i_clk)flag_high<=(reg_candidate[73:64]>10'd1000);
    // 阈值严格有序。
    always @(posedge i_clk)flag_order<=(reg_candidate[73:64]<=reg_candidate[83:74]);
    // 过期期限必须非零。
    always @(posedge i_clk)flag_age_zero<=(reg_candidate[63:0]==64'd0);
    // 最高位禁止负时间表示。
    always @(posedge i_clk)flag_age_sign<=reg_candidate[63];
    // C加二分别合并相关规则。
    always @(posedge i_clk)flag_identity_bad<=flag_node|flag_session|flag_epoch|flag_revision;
    // 窗口规则彼此独立。
    always @(posedge i_clk)flag_window_bad<=flag_window_zero|flag_window_large|flag_min_zero|flag_min_large;
    // 阈值组不跨越其他分组。
    always @(posedge i_clk)flag_threshold_bad<=flag_low|flag_high|flag_order;
    // 来源期限合法性分组。
    always @(posedge i_clk)flag_age_bad<=flag_age_zero|flag_age_sign;
    // C加三高组登记。
    always @(posedge i_clk)flag_high_bad<=flag_identity_bad|flag_window_bad;
    // C加三低组登记。
    always @(posedge i_clk)flag_low_bad<=flag_threshold_bad|flag_age_bad;
    // C加四最终非法位登记。
    always @(posedge i_clk)flag_bad<=flag_high_bad|flag_low_bad;
    // C加五只登记许可，当前复位可撤销。
    always @(posedge i_clk)commit_o<=({i_rst,reg_pipeline[4],flag_bad}==3'b010);
    // 拒绝是单拍诊断事件。
    always @(posedge i_clk)reject_o<=({i_rst,reg_pipeline[4],flag_bad}==3'b011);
    // C加六应用原子配置，复位清修订基准。
    always @(posedge i_clk) begin
        if(i_rst)active_o<=326'd0;
        else if(C_DELAY_ACTIVE==1)begin
            if(flag_active_apply)active_o<=reg_candidate;
        end
        else if(commit_o)active_o<=reg_candidate;
    end
    // 已配置标志必须随原子应用更新。
    always @(posedge i_clk) begin
        if(i_rst)configured_o<=1'b0;
        else if(commit_o)configured_o<=1'b1;
    end
    // 仅有效提交改变禁入毫秒。
    always @(posedge i_clk) begin
        if(commit_o)reg_commit_ms<=i_now_ms;
    end
endmodule
