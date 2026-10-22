`timescale 1ns / 1ps
// 四槽有序入口：完整请求登记后才分发，读响应保留到上游消费。
module gs_node_bus_router (
    input i_clk, // 全部寄存器使用的共同采样时钟
    input i_rst, // 同步撤销全部未完成事务
    input [31:0] i_wr_addr, // 上游局部字节写地址
    input [31:0] i_wr_data, // 与写地址一起登记的全字数据
    input i_wr_valid, // 上游写请求有效资格
    output o_wr_ready, // 写请求进入保留槽的许可
    input [31:0] i_rd_addr, // 上游局部字节读地址
    input i_rd_valid, // 上游读请求有效资格
    output o_rd_ready, // 不与同沿写请求竞争的读许可
    output [31:0] o_rd_data, // 已登记的目标响应内容
    output o_rd_valid, // 响应保留槽已占用
    input i_rd_ready, // 上游消费保留响应
    output [31:0] o_lane_addr, // 被锁定请求的槽内偏移
    output [31:0] o_lane_data, // 被锁定写事务的数据
    output [3:0] o_lane_wr_valid, // 独热目标写请求
    input [3:0] i_lane_wr_ready, // 四个目标的写准入
    output [3:0] o_lane_rd_valid, // 独热目标读请求
    input [3:0] i_lane_rd_ready, // 四个目标的读准入
    input [127:0] i_lane_rd_data, // 槽零位于最低字的响应集合
    input [3:0] i_lane_rd_valid, // 四个目标的响应资格
    output [3:0] o_lane_rd_ready // 仅被选目标可消费响应
);
    localparam [2:0] ST_IDLE=3'd0, ST_WRITE=3'd1, ST_READ=3'd2, ST_WAIT=3'd3, ST_HOLD=3'd4;
    reg [2:0] state_current, state_next; // 请求保留与响应等待状态
    reg [9:0] reg_offset; // 槽内地址不受后续上游变化影响
    reg [31:0] reg_write_data; // 接收沿捕获的写数据
    reg [1:0] reg_slot; // 完整事务固定的资源归属
    reg flag_legal; // 高位及字对齐检查的登记结果
    reg [31:0] reg_response_o; // 背压期间保持的读响应
    wire flag_idle; // 同步复位期间屏蔽入口
    wire flag_rstn; // 同步复位的低有效内部表示，不增加异步边沿
    wire flag_write_take; // 唯一写接收事件
    wire flag_read_take; // 唯一读接收事件
    wire flag_selected_write_ready; // 固定目标写许可
    wire flag_selected_read_ready; // 固定目标读许可
    wire flag_selected_response; // 固定目标响应到达
    wire [31:0] reg_selected_data; // 四路响应选择结果
    wire [3:0] dec_slot; // 资源编号的独热展开
    wire flag_write_issue, flag_read_issue, flag_response_wait; // 目标握手阶段
    assign flag_rstn = !i_rst;
    assign flag_idle = (state_current == ST_IDLE) & !i_rst;
    assign o_wr_ready = flag_idle;
    assign o_rd_ready = flag_idle & !i_wr_valid;
    assign flag_write_take = i_wr_valid & o_wr_ready;
    assign flag_read_take = i_rd_valid & o_rd_ready;
    assign o_rd_data = reg_response_o;
    assign o_rd_valid = (state_current == ST_HOLD) & !i_rst;
    assign o_lane_addr = {22'd0,reg_offset};
    assign o_lane_data = reg_write_data;
    assign dec_slot = 4'b0001 << reg_slot;
    assign flag_write_issue = (state_current == ST_WRITE) & flag_legal & !i_rst;
    assign flag_read_issue = (state_current == ST_READ) & flag_legal & !i_rst;
    assign flag_response_wait = (state_current == ST_WAIT) & flag_legal & !i_rst;
    assign o_lane_wr_valid = dec_slot & {4{flag_write_issue}};
    assign o_lane_rd_valid = dec_slot & {4{flag_read_issue}};
    assign o_lane_rd_ready = dec_slot & {4{flag_response_wait}};
    assign flag_selected_write_ready = i_lane_wr_ready[reg_slot];
    assign flag_selected_read_ready = i_lane_rd_ready[reg_slot];
    assign flag_selected_response = i_lane_rd_valid[reg_slot];
    assign reg_selected_data = i_lane_rd_data[reg_slot*32 +: 32];
    // 状态寄存只由全站复位和已计算的转移目标更新。
    always @(posedge i_clk) begin
        if(flag_rstn == 1'b0) begin
            state_current <= ST_IDLE;
        end else begin
            state_current <= state_next;
        end
    end
    // 单在途串行化保证读不能越过已接受但尚未送出的写。
    always @(*) begin
        state_next = state_current;
        case(state_current)
            ST_IDLE: begin
                if(i_wr_valid) begin
                    state_next = ST_WRITE;
                end else if(i_rd_valid) begin
                    state_next = ST_READ;
                end
            end
            ST_WRITE: begin
                if(!flag_legal || flag_selected_write_ready) begin
                    state_next = ST_IDLE;
                end
            end
            ST_READ: begin
                if(!flag_legal) begin
                    state_next = ST_HOLD;
                end else if(flag_selected_read_ready) begin
                    state_next = ST_WAIT;
                end
            end
            ST_WAIT: begin
                if(flag_selected_response) begin
                    state_next = ST_HOLD;
                end
            end
            ST_HOLD: begin
                if(i_rd_ready) begin
                    state_next = ST_IDLE;
                end
            end
            default: begin
                state_next = ST_IDLE;
            end
        endcase
    end
    // 接收时锁定全部路由元数据；非法地址仍完成但不送入任何目标。
    always @(posedge i_clk) begin
        if(flag_rstn == 1'b0) begin
            reg_offset <= 10'd0;
            reg_write_data <= 32'd0;
            reg_slot <= 2'd0;
            flag_legal <= 1'b0;
        end else if(flag_write_take) begin
            reg_offset <= i_wr_addr[9:0];
            reg_write_data <= i_wr_data;
            reg_slot <= i_wr_addr[11:10];
            flag_legal <= (i_wr_addr[31:12] == 20'd0) & (i_wr_addr[1:0] == 2'd0);
        end else if(flag_read_take) begin
            reg_offset <= i_rd_addr[9:0];
            reg_write_data <= i_wr_data;
            reg_slot <= i_rd_addr[11:10];
            flag_legal <= (i_rd_addr[31:12] == 20'd0) & (i_rd_addr[1:0] == 2'd0);
        end
    end
    // 无效读返回GSNA；有效读只在目标valid/ready同时成立时登记。
    always @(posedge i_clk) begin
        if(flag_rstn == 1'b0) begin
            reg_response_o <= 32'd0;
        end else if((state_current == ST_READ) & !flag_legal) begin
            reg_response_o <= 32'h47534e41;
        end else if(flag_response_wait & flag_selected_response) begin
            reg_response_o <= reg_selected_data;
        end
    end
endmodule
