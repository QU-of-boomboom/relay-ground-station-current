`timescale 1ns/1ps
// 同域毫秒计数，输出使能而非派生时钟；规格见gs_monitor_clock_spec.md。
module gs_monitor_clock #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000, // 每毫秒采样沿数
    parameter [62:0] C_INITIAL_MS=63'd0 // 仅边界测试时配置起始时间
)(
    
    input i_clk,
    input i_rst, // 同步高有效复位
    
    output o_tick,
    output o_rollover, // 起始沿及时间变更沿
    
    output [63:0] o_now_ms,
    output o_fault // 饱和时间及溢出故障
);
    reg [31:0] reg_count; // 毫秒内相位
    reg flag_last; // 提前登记末沿
    reg [62:0] reg_now; // 有符号合法范围内的时间
    reg [62:0] reg_next; // 非末沿期间提前计算下一时间
    reg flag_limit; // 提前登记饱和条件
    reg fault_o; // 饱和溢出锁存
    reg tick_o; // 提前登记首沿，避免跨模块比较链
    assign o_tick=tick_o; // 同域消费者采样使能
    assign o_rollover=flag_last; // 本沿时间可能更新，撤销旧发布
    assign o_now_ms={1'b0,reg_now}; // 永不对外暴露负时间
    assign o_fault=fault_o; // reset之前保持故障
    // 参数合法性由同名合同静态检查和仿真起始断言共同约束。
    // synthesis translate_off
    initial begin
        if(C_CLOCKS_PER_MS<32'd23)$fatal(1,"monitor period must be at least 23"); // 无效参数必须失败
    end
    // synthesis translate_on
    // 相位更新含明确同步清零。
    always @(posedge i_clk) begin
        if(i_rst)tick_o<=1'b1;
        else tick_o<=flag_last;
    end
    // 相位计数和首沿资格同行更新。
    always @(posedge i_clk) begin
        reg_count <= (i_rst | flag_last) ? 32'd0 : (reg_count+32'd1); // 提前末沿位隔断比较路径
    end
    // 提前一沿预测末沿，P至少23保证复位后有充分余量。
    always @(posedge i_clk) begin
        if(i_rst)flag_last<=1'b0;
        else flag_last<=(reg_count==C_CLOCKS_PER_MS-32'd2);
    end
    // 下个时间持续预计算，仅在真正末沿消费。
    always @(posedge i_clk) begin
        reg_next<=reg_now+63'd1;
    end
    // 饱和值提前登记，禁止回绕成零。
    always @(posedge i_clk) begin
        if(i_rst)flag_limit<=(C_INITIAL_MS==63'h7fffffffffffffff);
        else flag_limit<=(reg_now==63'h7fffffffffffffff);
    end
    // 更新沿只复制已经准备好的时间。
    always @(posedge i_clk) begin
        if(i_rst)reg_now<=C_INITIAL_MS;
        else if({flag_last,flag_limit}==2'b10)reg_now<=reg_next;
    end
    // 到达上限后的下一次推进锁存故障。
    always @(posedge i_clk) begin
        if(i_rst)fault_o<=1'b0;
        else fault_o<=fault_o | (flag_last & flag_limit);
    end
endmodule
