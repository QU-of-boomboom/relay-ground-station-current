`timescale 1ns/1ps
// 真实滑动窗口计数到质量证据；来源时间是PL结算接受时刻。
module gs_pdr_evidence_executor #(
    parameter [8:0] C_WINDOW=9'd8 // 硬件窗口容量，必须与监测策略一致
)(
    input i_clk, // 同钟接口
    input i_rst, // 同步高复位取消整笔
    input i_valid, // 原PDR事务命令
    input [255:0] i_command, // 不由CPU提供分子分母
    output o_ready, // 单笔所有权准入
    input i_configured, // 监测配置已应用
    input [223:0] i_active, // node/session/epoch/revision
    input [8:0] i_window, // 监测策略窗口
    input [63:0] i_now_ms, // 本地PL结算时基
    output o_done, // 完成事件，接收侧必须持续等待
    output [31:0] o_receipt, // 桥错误/执行器code/缓存receipt
    output [255:0] o_response, // 原executor完整响应
    output o_packet_valid, // 证据等待缓存接收
    output [371:0] o_packet, // 分子分母与同一份元数据
    input i_packet_ready, // 原缓存准入
    input i_packet_done, // 原缓存实际完成
    input [3:0] i_packet_receipt // 实际缓存结论
);
    localparam [3:0] C_IDLE=4'd0,C_COMPARE=4'd1,C_DECIDE=4'd2,C_SEND_EXEC=4'd3,C_WAIT_EXEC=4'd4,
                     C_ROUTE=4'd5,C_SEND_PACKET=4'd6,C_WAIT_PACKET=4'd7,C_REPORT=4'd8;
    reg [3:0] reg_state; // 单笔命令阶段
    reg [255:0] reg_command,reg_response; // 原请求和完成响应隔离
    reg [223:0] reg_active; // 接受时身份与修订
    reg [63:0] reg_source_ms,reg_sequence; // 原结算时刻和不回绕结果序号
    reg [8:0] reg_window; // 接受时策略窗口
    reg flag_configured; // 接受时配置资格
    reg flag_node_equal,flag_session_equal,flag_epoch_equal,flag_window_equal,flag_exhausted; // 宽比较寄存隔断
    reg [371:0] reg_packet; // 等待缓存时保持
    reg [31:0] reg_receipt; // 最后完成结果
    wire executor_ready,executor_valid; // 真执行器握手
    wire [255:0] executor_response; // 真执行器完整统计
    wire flag_execute,flag_take; // 执行器发送与取回
    assign o_ready=(!i_rst) & (reg_state==C_IDLE);
    assign o_done=(!i_rst) & (reg_state==C_REPORT);
    assign o_receipt=reg_receipt;
    assign o_response=reg_response;
    assign o_packet_valid=(!i_rst) & (reg_state==C_SEND_PACKET);
    assign o_packet=reg_packet;
    assign flag_execute=(!i_rst) & (reg_state==C_SEND_EXEC);
    assign flag_take=(!i_rst) & (reg_state==C_WAIT_EXEC);
    gs_pdr_executor #(.WINDOW(C_WINDOW)) Executor_Inst(
        .clk(i_clk),.rst(i_rst),.cmd_data(reg_command),.cmd_valid(flag_execute),.cmd_ready(executor_ready),
        .rsp_data(executor_response),.rsp_valid(executor_valid),.rsp_ready(flag_take));
    // 每个身份比较先寄存，不能把多个宽比较直接串入发送valid。
    always @(posedge i_clk) begin
        if(i_rst)begin
            flag_node_equal<=1'b0;flag_session_equal<=1'b0;flag_epoch_equal<=1'b0;flag_window_equal<=1'b0;flag_exhausted<=1'b0;
        end else if(reg_state==C_COMPARE)begin
            flag_node_equal<=(reg_command[127:96]==reg_active[223:192]);
            flag_session_equal<=(reg_command[191:128]==reg_active[191:128]);
            flag_epoch_equal<=(reg_command[95:32]==reg_active[127:64]);
            flag_window_equal<=(reg_window==C_WINDOW);
            flag_exhausted<=(reg_sequence==64'hffffffffffffffff);
        end
    end
    // 请求接受、执行、证据发送、完成顺序清晰分拍，背压期间不刷新来源时间。
    always @(posedge i_clk) begin
        if(i_rst)begin
            reg_state<=C_IDLE;reg_command<=256'd0;reg_response<=256'd0;reg_active<=224'd0;reg_source_ms<=64'd0;
            reg_sequence<=64'd0;reg_window<=9'd0;flag_configured<=1'b0;reg_packet<=372'd0;reg_receipt<=32'd0;
        end else begin
            case(reg_state)
                C_IDLE:if(i_valid)begin
                    reg_command<=i_command;reg_active<=i_active;reg_source_ms<=i_now_ms;reg_window<=i_window;
                    flag_configured<=i_configured;reg_response<=256'd0;reg_receipt<=32'd0;reg_state<=C_COMPARE;
                end
                C_COMPARE:reg_state<=C_DECIDE;
                C_DECIDE:begin
                    if(!flag_configured)begin reg_receipt<=32'h00010000;reg_state<=C_REPORT;end
                    else if((!flag_node_equal) | (!flag_session_equal) | (!flag_epoch_equal))begin reg_receipt<=32'h00020000;reg_state<=C_REPORT;end
                    else if(!flag_window_equal)begin reg_receipt<=32'h00030000;reg_state<=C_REPORT;end
                    else if(flag_exhausted)begin reg_receipt<=32'h00040000;reg_state<=C_REPORT;end
                    else reg_state<=C_SEND_EXEC;
                end
                C_SEND_EXEC:if(executor_ready)reg_state<=C_WAIT_EXEC;
                C_WAIT_EXEC:if(executor_valid)begin reg_response<=executor_response;reg_state<=C_ROUTE;end
                C_ROUTE:begin
                    reg_receipt<={16'd0,reg_response[23:16],8'd0};
                    if((reg_response[23:16]==8'd0) & ((reg_command[7:0]==8'd1) | (reg_command[7:0]==8'd2)))begin
                        reg_sequence<=reg_sequence+64'd1;
                        reg_packet<={reg_response[136:128],reg_response[145:137],reg_active,reg_sequence+64'd1,reg_source_ms,2'b11};
                        reg_state<=C_SEND_PACKET;
                    end else reg_state<=C_REPORT;
                end
                C_SEND_PACKET:if(i_packet_ready)reg_state<=C_WAIT_PACKET;
                C_WAIT_PACKET:if(i_packet_done)begin reg_receipt<={28'd0,i_packet_receipt};reg_state<=C_REPORT;end
                C_REPORT:reg_state<=C_IDLE;
                default:reg_state<=C_IDLE;
            endcase
        end
    end
endmodule
