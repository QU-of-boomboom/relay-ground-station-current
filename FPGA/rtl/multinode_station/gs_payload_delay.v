`timescale 1ns / 1ps
// 固定延迟宽载荷：同步旧值读取环形BRAM，复位仅撤销资格。
module gs_payload_delay #(
    parameter integer C_WIDTH=434, // 同行元数据位宽，至少一位
    parameter integer C_DELAY=18 // 接受沿至输出的间隔，至少两拍
)(
    input i_clk, // 唯一同步读写时钟
    input i_rst, // 同步高复位清地址和预热，不清存储阵列
    input [C_WIDTH-1:0] i_payload, // 每拍接受完整载荷，包括业务空泡
    output [C_WIDTH-1:0] o_payload // 输入沿后C_DELAY沿输出，复位预热为零
);
    localparam integer LP_ADDRESS_WIDTH=$clog2(C_DELAY); // 环地址最小位宽
    (* ram_style="block" *) reg [C_WIDTH-1:0] mem_payload [0:C_DELAY-1]; // 同址读旧值的同步存储
    reg [LP_ADDRESS_WIDTH-1:0] reg_address; // 下一次将覆盖的最旧位置
    reg [C_WIDTH-1:0] reg_read; // BRAM同步读出的覆盖前载荷
    reg [C_DELAY:0] reg_warm; // 防止复位前存储内容重新可见
    assign o_payload=reg_warm[C_DELAY] ? reg_read : {C_WIDTH{1'b0}};
    always @(posedge i_clk) begin
        if(i_rst) begin
            reg_address<=0;
            reg_warm<=0;
        end else begin
            if(reg_address==C_DELAY-1) begin
                reg_address<=0;
            end else begin
                reg_address<=reg_address+1'b1;
            end
            reg_warm<={reg_warm[C_DELAY-1:0],1'b1};
        end
    end
    // 此进程不清存储内容或读数据，才能推断真实BRAM。
    // 非阻塞赋值使读口观察当沿覆盖前的内容。
    always @(posedge i_clk) begin
        if(!i_rst) begin
            mem_payload[reg_address]<=i_payload;
            reg_read<=mem_payload[reg_address];
        end
    end
endmodule
