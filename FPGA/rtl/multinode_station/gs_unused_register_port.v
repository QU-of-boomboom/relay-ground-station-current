`timescale 1ns / 1ps
// Unused register window: consume writes and return GSNA for reads.
// 未使用寄存器窗口：写入不产生副作用；读返回GSNA并保持至握手完成。
module gs_unused_register_port (
    input wire clk,
    input wire rst_n,
    input wire rd_valid,
    output wire rd_ready,
    output wire [31:0] rd_data,
    output reg rd_data_valid,
    input wire rd_data_ready,
    output wire wr_ready
);
    assign wr_ready = rst_n;
    assign rd_ready = rst_n && !rd_data_valid;
    assign rd_data = 32'h47534e41;
    // One outstanding response; backpressure cannot change its data or valid.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data_valid <= 1'b0;
        else if (rd_valid && rd_ready)
            rd_data_valid <= 1'b1;
        else if (rd_data_valid && rd_data_ready)
            rd_data_valid <= 1'b0;
    end
endmodule
