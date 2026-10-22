`timescale 1ns/1ps
// 原子配置与证据输入：同步控制银行，见同名合同。
module gs_monitor_control_bank(
    input i_clk, // 同域时钟
    input i_rst, // 同步高复位
    input [31:0] i_wr_addr, // 本地写字节偏移
    input [31:0] i_wr_data, // 全字写数据
    input i_wr_valid, // 写请求
    output o_wr_ready, // 写接受
    input [31:0] i_rd_addr, // 本地读字节偏移
    input i_rd_valid, // 读请求
    output o_rd_ready, // 读接受
    output [31:0] o_rd_data, // 注册读响应
    output o_rd_valid, // 响应有效
    input i_rd_ready, // 响应消费
    output o_config_valid, // 保持至配置握手
    output [325:0] o_config, // 冻结完整配置
    input i_config_ready, // 核心配置准入
    input i_config_commit, // 核心配置准备完成
    input i_config_reject, // 核心配置拒绝
    output o_packet_valid, // 保持至证据握手
    output [371:0] o_packet, // 冻结完整统计证据
    input i_packet_ready, // 核心证据准入
    input i_packet_done, // 缓存真实完成
    input [3:0] i_receipt, // 缓存接收结果
    output o_settle_valid, // 新增硬件统计事务
    output [255:0] o_settle, // 原PDR事务完整请求
    input i_settle_ready, // 统计桥准入
    input i_settle_done, // 统计桥及证据提交均已完成
    input [31:0] i_settle_receipt, // 桥/统计/缓存结果
    input [255:0] i_settle_response // 原统计器完整响应
);
    localparam [2:0] C_IDLE=3'd0,C_SEND_CONFIG=3'd1,C_WAIT_CONFIG=3'd2,
                     C_APPLY_CONFIG=3'd3,C_SEND_PACKET=3'd4,C_WAIT_PACKET=3'd5,C_SEND_SETTLE=3'd6,C_WAIT_SETTLE=3'd7;
    reg [2:0] reg_state; // 单笔命令生命周期
    reg [383:0] reg_shadow,reg_command; // 影子写和已提交完整快照隔离
    reg [11:0] reg_written; // 十二字完整性掩码
    reg [255:0] reg_settle_response; // 完成后冻结的统计响应
    reg [31:0] reg_error,reg_receipt; // 协议错误及业务完成结果
    reg flag_done,flag_success; // 完成粘滞标志
    reg [31:0] reg_read_data; // 背压保持读响应
    reg flag_read_valid; // 单槽读有效
    reg [31:0] wire_read_value,wire_read_error,wire_write_error; // 组合译码默认完整
    wire flag_write,flag_read,flag_shadow; // 握手及影子范围
    assign o_wr_ready=!i_rst;
    assign o_rd_ready=(!i_rst) & (!flag_read_valid);
    assign o_rd_data=reg_read_data;
    assign o_rd_valid=(!i_rst) & flag_read_valid;
    assign flag_write=i_wr_valid & o_wr_ready;
    assign flag_read=i_rd_valid & o_rd_ready;
    assign flag_shadow=(i_wr_addr>=32'h40) & (i_wr_addr<=32'h6c) & (i_wr_addr[1:0]==2'b00);
    assign o_config_valid=(!i_rst) & (reg_state==C_SEND_CONFIG);
    assign o_config=reg_command[325:0];
    assign o_packet_valid=(!i_rst) & (reg_state==C_SEND_PACKET);
    assign o_packet=reg_command[371:0];
    assign o_settle_valid=(!i_rst) & (reg_state==C_SEND_SETTLE);
    assign o_settle=reg_command[255:0];
    // 只在明确地址取固定字，防止越界索引或地址别名。
    always @(*) begin
        wire_read_value=32'd0;wire_read_error=32'd0;
        case(i_rd_addr)
            32'h00:wire_read_value=32'h47534331;
            32'h04:wire_read_value=32'h0002000c;
            32'h08:wire_read_value={28'd0,(reg_error!=32'd0),flag_success,flag_done,(reg_state!=C_IDLE)};
            32'h10:wire_read_value=reg_receipt;
            32'h14:wire_read_value=reg_error;
            32'h18:wire_read_value={20'd0,reg_written};
            32'h80:wire_read_value=reg_settle_response[31:0];
            32'h84:wire_read_value=reg_settle_response[63:32];
            32'h88:wire_read_value=reg_settle_response[95:64];
            32'h8c:wire_read_value=reg_settle_response[127:96];
            32'h90:wire_read_value=reg_settle_response[159:128];
            32'h94:wire_read_value=reg_settle_response[191:160];
            32'h98:wire_read_value=reg_settle_response[223:192];
            32'h9c:wire_read_value=reg_settle_response[255:224];
            32'h40:wire_read_value=reg_shadow[31:0];
            32'h44:wire_read_value=reg_shadow[63:32];
            32'h48:wire_read_value=reg_shadow[95:64];
            32'h4c:wire_read_value=reg_shadow[127:96];
            32'h50:wire_read_value=reg_shadow[159:128];
            32'h54:wire_read_value=reg_shadow[191:160];
            32'h58:wire_read_value=reg_shadow[223:192];
            32'h5c:wire_read_value=reg_shadow[255:224];
            32'h60:wire_read_value=reg_shadow[287:256];
            32'h64:wire_read_value=reg_shadow[319:288];
            32'h68:wire_read_value=reg_shadow[351:320];
            32'h6c:wire_read_value=reg_shadow[383:352];
            default:wire_read_error=32'd1;
        endcase
    end
    // 单笔命令占有核心，禁止修改正在发送的元数据。
    always @(*) begin
        wire_write_error=32'd0;
        if(reg_state!=C_IDLE)wire_write_error=32'd3;
        else if(flag_shadow)wire_write_error=32'd0;
        else if(i_wr_addr==32'h1c)begin
            if(i_wr_data!=32'd1)wire_write_error=32'd2;
        end else if(i_wr_addr!=32'h0c)wire_write_error=32'd1;
        else if((i_wr_data!=32'd1) & (i_wr_data!=32'd2) & (i_wr_data!=32'd3))wire_write_error=32'd2;
        else if(reg_error!=32'd0)wire_write_error=32'd6;
        else if(reg_written!=12'hfff)wire_write_error=32'd4;
        else if((i_wr_data==32'd1) & (reg_shadow[383:326]!=58'd0))wire_write_error=32'd5;
        else if((i_wr_data==32'd2) & (reg_shadow[383:372]!=12'd0))wire_write_error=32'd5;
        else if((i_wr_data==32'd3) & (reg_shadow[383:256]!=128'd0))wire_write_error=32'd5;
    end
    // 同沿读观察旧状态，响应只有真正消费才撤销。
    always @(posedge i_clk) begin
        if(i_rst)begin reg_read_data<=32'd0;flag_read_valid<=1'b0;end
        else if(flag_read)begin reg_read_data<=wire_read_value;flag_read_valid<=1'b1;end
        else if(i_rd_ready)flag_read_valid<=1'b0;
    end
    // 控制和载荷一同提交；同步复位取消任意在途状态。
    always @(posedge i_clk) begin
        if(i_rst)begin
            reg_state<=C_IDLE;reg_shadow<=384'd0;reg_command<=384'd0;reg_written<=12'd0;
            reg_error<=32'd0;reg_receipt<=32'd0;flag_done<=1'b0;flag_success<=1'b0;
            reg_settle_response<=256'd0;
        end else begin
            case(reg_state)
                C_SEND_CONFIG:if(i_config_ready)reg_state<=C_WAIT_CONFIG;
                C_WAIT_CONFIG:begin
                    if(i_config_reject)begin reg_state<=C_IDLE;flag_done<=1'b1;flag_success<=1'b0;reg_receipt<=32'd1;end
                    else if(i_config_commit)reg_state<=C_APPLY_CONFIG;
                end
                C_APPLY_CONFIG:begin reg_state<=C_IDLE;flag_done<=1'b1;flag_success<=1'b1;reg_receipt<=32'd0;end
                C_SEND_PACKET:if(i_packet_ready)reg_state<=C_WAIT_PACKET;
                C_WAIT_PACKET:if(i_packet_done)begin
                    reg_state<=C_IDLE;flag_done<=1'b1;flag_success<=(i_receipt==4'd1);reg_receipt<={28'd0,i_receipt};
                end
                C_SEND_SETTLE:if(i_settle_ready)reg_state<=C_WAIT_SETTLE;
                C_WAIT_SETTLE:if(i_settle_done)begin
                    reg_state<=C_IDLE;flag_done<=1'b1;flag_success<=((i_settle_receipt==32'd0) | (i_settle_receipt==32'd1));
                    reg_receipt<=i_settle_receipt;reg_settle_response<=i_settle_response;
                end
                default:reg_state<=C_IDLE;
            endcase
            if(flag_write & (wire_write_error==32'd0))begin
                if(flag_shadow)begin
                    case(i_wr_addr)
                        32'h40:begin reg_shadow[31:0]<=i_wr_data;reg_written[0]<=1'b1;end
                        32'h44:begin reg_shadow[63:32]<=i_wr_data;reg_written[1]<=1'b1;end
                        32'h48:begin reg_shadow[95:64]<=i_wr_data;reg_written[2]<=1'b1;end
                        32'h4c:begin reg_shadow[127:96]<=i_wr_data;reg_written[3]<=1'b1;end
                        32'h50:begin reg_shadow[159:128]<=i_wr_data;reg_written[4]<=1'b1;end
                        32'h54:begin reg_shadow[191:160]<=i_wr_data;reg_written[5]<=1'b1;end
                        32'h58:begin reg_shadow[223:192]<=i_wr_data;reg_written[6]<=1'b1;end
                        32'h5c:begin reg_shadow[255:224]<=i_wr_data;reg_written[7]<=1'b1;end
                        32'h60:begin reg_shadow[287:256]<=i_wr_data;reg_written[8]<=1'b1;end
                        32'h64:begin reg_shadow[319:288]<=i_wr_data;reg_written[9]<=1'b1;end
                        32'h68:begin reg_shadow[351:320]<=i_wr_data;reg_written[10]<=1'b1;end
                        32'h6c:begin reg_shadow[383:352]<=i_wr_data;reg_written[11]<=1'b1;end
                    endcase
                end else if(i_wr_addr==32'h1c)begin flag_done<=1'b0;flag_success<=1'b0;reg_error<=32'd0;end
                else if(i_wr_addr==32'h0c)begin
                    reg_command<=reg_shadow;reg_written<=12'd0;flag_done<=1'b0;flag_success<=1'b0;reg_receipt<=32'd0;
                    reg_settle_response<=256'd0;
                    if(i_wr_data==32'd1)reg_state<=C_SEND_CONFIG;
                    else if(i_wr_data==32'd2)reg_state<=C_SEND_PACKET;
                    else reg_state<=C_SEND_SETTLE;
                end
            end
            if(flag_read & (wire_read_error!=32'd0))reg_error<=wire_read_error;
            if(flag_write & (wire_write_error!=32'd0))reg_error<=wire_write_error;
        end
    end
endmodule
