`timescale 1ns/1ps
// 配置、真实时基、接收缓存和质量发布闭环；规格见gs_cached_monitor_spec.md。
module gs_cached_monitor #(parameter [31:0] C_CLOCKS_PER_MS=32'd200000)(
    
    input i_clk,
    input i_rst, // 共同同步域
    
    input i_config_valid,
    input [325:0] i_config, // 配置请求
    
    input i_valid,
    input [371:0] i_packet, // 统计证据请求
    
    output o_config_ready,
    output o_config_commit,
    output o_config_reject, // 配置诊断
    
    output [325:0] o_config,
    output o_configured, // 生效配置
    
    output [63:0] o_now_ms,
    output o_tick,
    output o_clock_fault, // 真实硬件时基
    
    output o_ready,
    output o_done,
    output [3:0] o_receipt, // 接收诊断
    
    output [438:0] o_cache,
    output [7:0] o_generation, // 原子缓存及发布代号
    
    output o_request,
    output o_schedule_fault, // 重评诊断
    
    output o_publication,
    output o_current_valid,
    output [441:0] o_current_payload, // 最终发布
    output o_rollover, // 当前沿关闭旧毫秒窗口
    output o_cache_change, // 当前沿提交银行并增代
`ifdef GS_SHARED_QUALITY
    output o_compute_request, // S沿质量重评请求，原样送往共享队列
    output o_compute_cancel, // 本来源复位或缓存变化，撤销旧计算
    output [778:0] o_compute_payload, // 与请求同行的完整原始质量输入
    output [7:0] o_compute_generation, // 与输入同行的本沿新代号
    input i_compute_valid, // 仅本来源的共享返回资格
    input [7:0] i_compute_generation, // 返回结果保留的原请求代号
    input [441:0] i_compute_payload, // 原质量结果，不刷新评估时刻
`endif
    output o_alarm_clear // 配置准备/应用期间提前清告警
);
    wire [63:0] wire_now; // 共同时间
    wire flag_tick,flag_rollover,flag_clock_fault; // 时基使能
    wire flag_commit,flag_configured,flag_inhibit; // 配置控制
    wire [325:0] wire_config; // 活动配置
    wire [438:0] wire_cache; // 原子银行反馈
    wire [439:0] wire_transaction,wire_bank_transaction; // 写口事务
    wire flag_change,flag_blocked,flag_suppress,flag_receive_inhibit; // 发布/接收控制
    wire [7:0] wire_generation; // 当前发布代号
    reg [439:0] reg_bank_transaction; // 真正的事务寄存边界，银行延后一沿提交
`ifdef GS_COMPACT_STORAGE
    wire [325:0] reg_config; // 配置器已在银行清除沿应用，无须第二份存储
`else
    reg [325:0] reg_config; // 与银行清除沿对齐的活动配置
`endif
    reg reg_configured; // 与活动配置一起延迟
    reg reg_inhibit; // 接收许可的寄存边界
    wire wire_done; // 原接收器R加七回执
    wire [3:0] wire_receipt; // 原接收器原因
    reg reg_done; // 闭环R加八提交回执
    reg [3:0] reg_receipt; // 与提交对齐的原因
    reg flag_config_apply; // 准备提交后一沿对应对外配置应用
    reg flag_refresh; // 银行提交后一沿重评新Q
    assign o_rollover=flag_rollover; // 与真实时基共用资格
    assign o_cache_change=flag_change; // 与发布控制共用事务事件
    assign o_alarm_clear=flag_commit | flag_config_apply; // 配置取消与应用连续覆盖
    // 登记配置事件，供同域下游明确识别应用边界。
    always @(posedge i_clk) begin
        if(i_rst)flag_config_apply<=1'b0;
        else flag_config_apply<=flag_commit;
    end
    // 新缓存不必等到下一个毫秒；剩余时间不足仍由发布资格撤销。
    always @(posedge i_clk) begin
        if(i_rst)flag_refresh<=1'b0;
        else flag_refresh<=flag_change;
    end
    assign flag_change=reg_bank_transaction[439]; // 真实寄存事务就是本沿增代事件
    assign flag_blocked=({reg_configured,wire_cache[437],flag_clock_fault} != 3'b100); // 三项资格单次判定
    assign flag_suppress=({reg_inhibit,flag_change,flag_rollover} != 3'b000); // 写沿与换毫秒沿禁止发布
    assign flag_receive_inhibit=reg_inhibit; // 准入只读取已登记的许可
    assign wire_bank_transaction=flag_commit ? {1'b1,439'd0} : wire_transaction; // 配置清除优先
    assign o_config=reg_config; // 对外观察与银行清除同行的配置
    assign o_config_commit=flag_commit; // 下一沿清除和应用
    assign o_configured=reg_configured; // 对外观察初始禁用
    assign o_done=reg_done; // 与真实银行提交同行
    assign o_receipt=reg_receipt; // 完整延迟回执
    assign o_now_ms=wire_now; // 真实计数结果
    assign o_tick=flag_tick; // 同域使能
    assign o_clock_fault=flag_clock_fault; // 时间饱和故障
    assign o_cache=wire_cache; // 完整缓存快照
    assign o_generation=wire_generation; // 完整代号
    // 寄存完整银行事务，复位禁止下一沿重放旧写入。
    always @(posedge i_clk) begin
        if(i_rst)reg_bank_transaction<=440'd0;
        else reg_bank_transaction<=wire_bank_transaction;
    end
    // 配置晚一沿对外生效，与配置清空事务一起到达银行。
`ifdef GS_COMPACT_STORAGE
    assign reg_config=wire_config; // 延迟模式已在配置器内部形成相同C加七寄存边界
`else
    always @(posedge i_clk) begin
        if(i_rst)reg_config<=326'd0;
        else reg_config<=wire_config;
    end
`endif
    // 配置资格和完整配置共用相同边界。
    always @(posedge i_clk) begin
        if(i_rst)reg_configured<=1'b0;
        else reg_configured<=flag_configured;
    end
    // 禁入延迟解除一拍，提交取消接收器使延迟断言不会接纳旧配置。
    always @(posedge i_clk) begin
        if(i_rst)reg_inhibit<=1'b1;
        else reg_inhibit<=flag_inhibit | flag_clock_fault;
    end
    // 提交或复位取消已经进入最后一级的回执。
    always @(posedge i_clk) begin
        reg_done<=({i_rst,wire_done}==2'b01);
    end
    // 原因只随真实回执有效，清除期间固定为零。
    always @(posedge i_clk) begin
        reg_receipt<=i_rst ? 4'd0 : wire_receipt;
    end
    gs_monitor_clock #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS)) Clock_Inst( // 实际分频和时间计数
        .i_clk(i_clk),.i_rst(i_rst),.o_tick(flag_tick),.o_rollover(flag_rollover),.o_now_ms(wire_now),.o_fault(flag_clock_fault));
`ifdef GS_COMPACT_STORAGE
    gs_monitor_config #(.C_DELAY_ACTIVE(1)) Config_Inst( // 内部数据应用移到闭环C加七
`else
    gs_monitor_config Config_Inst( // 实际配置合法性及原子应用
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_valid(i_config_valid),.i_config(i_config),.i_now_ms(wire_now),
        .o_ready(o_config_ready),.o_commit(flag_commit),.o_reject(o_config_reject),.o_configured(flag_configured),
        .o_inhibit(flag_inhibit),.o_active(wire_config));
`ifdef GS_COMPACT_STORAGE
`ifdef GS_FROZEN_CACHE
    gs_cache_receiver_frozen Receiver_Inst( // 复用稳定选取数据，原七拍提交不变
`else
    gs_cache_receiver_compact Receiver_Inst( // 单在途直接冻结，保持原回执周期
`endif
`else
    gs_cache_receiver Receiver_Inst( // 准入判定使用真实银行与配置
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_cancel(flag_commit),.i_inhibit(flag_receive_inhibit),.i_valid(i_valid),
        .i_packet(i_packet),.i_cache(wire_cache),.i_active(reg_config[325:102]),.i_window(reg_config[101:93]),.i_now_ms(wire_now),
        .o_ready(o_ready),.o_transaction(wire_transaction),.o_done(wire_done),.o_receipt(wire_receipt));
    gs_evidence_cache_bank Bank_Inst( // 真正存储，非测试台代算
        .i_clk(i_clk),.i_rst(i_rst),.i_transaction(reg_bank_transaction),.o_cache(wire_cache));
    gs_quality_publication #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS)) Publication_Inst( // 九模块质量与发布链
`ifdef GS_SHARED_QUALITY
        .o_compute_request(o_compute_request),.o_compute_cancel(o_compute_cancel),
        .o_compute_payload(o_compute_payload),.o_compute_generation(o_compute_generation),
        .i_compute_valid(i_compute_valid),.i_compute_generation(i_compute_generation),.i_compute_payload(i_compute_payload),
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_change(flag_change),.i_blocked(flag_blocked),.i_suppress(flag_suppress),.i_tick(flag_tick | flag_refresh),
        .i_count(wire_cache[371:363]),.i_delivered(wire_cache[362:354]),.i_window(reg_config[101:93]),
        .i_minimum(reg_config[92:84]),.i_low(reg_config[83:74]),.i_high(reg_config[73:64]),.i_active(reg_config[325:102]),
        .i_context(wire_cache[353:0]),.i_tag({8'd0,wire_generation}),.i_evidence_present(wire_cache[438]),
        .i_now_ms(wire_now),.i_max_age_ms(reg_config[63:0]),.o_generation(wire_generation),.o_request(o_request),
        .o_schedule_fault(o_schedule_fault),.o_publication(o_publication),.o_current_valid(o_current_valid),.o_current_payload(o_current_payload));
endmodule
