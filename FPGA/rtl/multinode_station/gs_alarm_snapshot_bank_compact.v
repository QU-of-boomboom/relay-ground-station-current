`timescale 1ns/1ps
// 原子告警快照寄存器：独立本地全字接口，未上板。
module gs_alarm_snapshot_bank_compact(
    input i_clk, // 同一时钟域
    input i_rst, // 同步高复位
    input i_clear, // 同步撤销旧会话
    input i_snapshot, // 新记录事件
    input [799:0] i_payload, // 完整原子记录
    input [31:0] i_wr_addr, // 本地写字节偏移
    input [31:0] i_wr_data, // 全字写入数据
    input i_wr_valid, // 写请求
    output o_wr_ready, // 写接受
    input [31:0] i_rd_addr, // 本地字节偏移
    input i_rd_valid, // 读请求
    output o_rd_ready, // 读接受
    output [31:0] o_rd_data, // 注册响应
    output o_rd_valid, // 响应有效
    input i_rd_ready // 响应消费
);
    reg [1:0] reg_latest_bank,reg_frozen_bank; // 三银行指针，锁定记录不再复制
    reg [1:0] wire_write_bank; // 避开仍需保留的最新与冻结银行
    wire [799:0] wire_memory_words; // 同步RAM读端，未接受新读时保持
    reg [4:0] reg_read_word; // 同笔响应的25字选择
    reg flag_payload_response; // 禁止未捕获或未初始化内容暴露
    wire flag_payload_address;
    genvar gen_word;
    reg [31:0] reg_token; // 当前独占客户端捕获编号
    reg [31:0] reg_error; // 粘滞协议错误
    reg flag_available,flag_locked; // 最新及冻结记录资格
    reg [31:0] reg_read_data; // 背压保持响应
    reg flag_read_valid; // 一笔未消费响应
    reg [31:0] wire_read_value,wire_read_error,wire_write_error; // 完整赋值的组合译码
    wire flag_read,flag_write; // 真实握手
    assign o_wr_ready=!i_rst; // 清除期间写接受但被同步撤销
    assign o_rd_ready=(!i_rst) & (!flag_read_valid); // 不覆盖待取响应
    assign o_rd_data=flag_payload_response ? wire_memory_words[reg_read_word*32 +: 32] : reg_read_data; // 直到消费或复位保持
    assign o_rd_valid=(!i_rst) & flag_read_valid; // 复位屏蔽总线有效
    assign flag_read=i_rd_valid & o_rd_ready; // 接受地址
    assign flag_write=i_wr_valid & o_wr_ready; // 接受写入
    assign flag_payload_address=(i_rd_addr[31:8]==24'd0) & (i_rd_addr[1:0]==2'd0) &
        (i_rd_addr[7:2]>=6'd16) & (i_rd_addr[7:2]<=6'd40);
    // 三位置至少一个空闲；始终避开旧latest以保证同沿capture语义。
    always @(*) begin
        if((reg_latest_bank!=2'd0) & ((!flag_locked) | (reg_frozen_bank!=2'd0)))wire_write_bank=2'd0;
        else if((reg_latest_bank!=2'd1) & ((!flag_locked) | (reg_frozen_bank!=2'd1)))wire_write_bank=2'd1;
        else wire_write_bank=2'd2;
    end
    generate
        for(gen_word=0;gen_word<25;gen_word=gen_word+1)begin:gen_memory
            (* ram_style="block" *) reg [31:0] mem_words[0:2];
            reg [31:0] reg_word_output;
            assign wire_memory_words[gen_word*32 +: 32]=reg_word_output;
            // 独立读写口；clear不清RAM也不撤销本沿已经接受的旧记录读取。
            always @(posedge i_clk)begin
                if(i_rst | i_clear)begin
                    // 只清控制资格，存储阵列无复位端。
                end else if(i_snapshot)begin
                    mem_words[wire_write_bank]<=i_payload[gen_word*32 +: 32];
                end
                if(flag_read & flag_locked & flag_payload_address)
                    reg_word_output<=mem_words[reg_frozen_bank];
            end
        end
    endgenerate
    always @(posedge i_clk)begin
        if(i_rst)begin flag_payload_response<=1'b0;reg_read_word<=5'd0;end
        else if(flag_read)begin
            flag_payload_response<=flag_locked & flag_payload_address;
            reg_read_word<=i_rd_addr[7:2]-6'd16;
        end
    end
    // 寄存器及错误译码与旧实现相同，payload数据改由RAM同步读口提供。
    always @(*) begin
        wire_read_value=32'd0;wire_read_error=32'd0;
        case(i_rd_addr)
            32'h00:wire_read_value=32'h47534131;
            32'h04:wire_read_value=32'h00010019;
            32'h08:wire_read_value={30'd0,flag_locked,flag_available};
            32'h0c:wire_read_value=reg_token;
            32'h10:wire_read_value=reg_error;
            32'h40:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h44:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h48:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h4c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h50:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h54:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h58:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h5c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h60:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h64:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h68:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h6c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h70:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h74:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h78:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h7c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h80:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h84:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h88:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h8c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h90:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h94:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h98:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'h9c:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            32'ha0:begin wire_read_value=32'd0;wire_read_error=flag_locked ? 32'd0 : 32'd1;end
            default:wire_read_error=32'd1;
        endcase
    end
    // 捕获和释放禁止穿越未消费读响应，非法写优先记录。
    always @(*) begin
        wire_write_error=32'd0;
        if(i_wr_addr==32'h1c)begin
            if(i_wr_data!=32'd1)wire_write_error=32'd2;
        end else if((i_wr_addr==32'h14) | (i_wr_addr==32'h18))begin
                if(i_wr_data==32'd0)wire_write_error=32'd2;
                else if(flag_read_valid | flag_read)wire_write_error=32'd3;
                else if(i_wr_addr==32'h14)begin
                    if(flag_locked)wire_write_error=32'd3;
                    else if(!flag_available)wire_write_error=32'd4;
                    else if(reg_error!=32'd0)wire_write_error=32'd6;
                end else if((!flag_locked) | (i_wr_data!=reg_token))wire_write_error=32'd5;
        end else wire_write_error=32'd1;
    end
    // 同沿读返回旧Q；clear不破坏已接受响应的背压契约。
    always @(posedge i_clk) begin
        if(i_rst)begin reg_read_data<=32'd0;flag_read_valid<=1'b0;end
        else if(flag_read)begin reg_read_data<=wire_read_value;flag_read_valid<=1'b1;end
        else if(i_rd_ready)flag_read_valid<=1'b0;
    end
    // 清除最高优先，新发布永不直接覆盖被冻结的记录。
    always @(posedge i_clk) begin
        if(i_rst | i_clear)begin
            reg_latest_bank<=2'd0;reg_frozen_bank<=2'd0;reg_token<=32'd0;reg_error<=32'd0;
            flag_available<=1'b0;flag_locked<=1'b0;
        end else begin
            if(i_snapshot)begin reg_latest_bank<=wire_write_bank;flag_available<=1'b1;end
            if(flag_write & (wire_write_error==32'd0))begin
                if(i_wr_addr==32'h14)begin
                    reg_frozen_bank<=reg_latest_bank;reg_token<=i_wr_data;flag_locked<=1'b1;
                end else if(i_wr_addr==32'h18)begin
                    reg_frozen_bank<=2'd0;reg_token<=32'd0;flag_locked<=1'b0;
                end else if(i_wr_addr==32'h1c)reg_error<=32'd0;
            end
            if(flag_read & (wire_read_error!=32'd0))reg_error<=wire_read_error;
            if(flag_write & (wire_write_error!=32'd0))reg_error<=wire_write_error;
        end
    end
endmodule

