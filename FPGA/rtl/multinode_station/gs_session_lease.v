`timescale 1ns / 1ps
// PS生命周期随机标记：全PS复位清零，使复位代归零也不能复用旧软件资格。
module gs_session_lease (
    input i_clk,input i_rst,
    input [31:0] i_wr_addr,input [31:0] i_wr_data,input i_wr_valid,output o_wr_ready,
    input [31:0] i_rd_addr,input i_rd_valid,output o_rd_ready,
    output [31:0] o_rd_data,output o_rd_valid,input i_rd_ready
);
    reg [63:0] reg_shadow,reg_active;
    reg [1:0] reg_written;
    reg [31:0] reg_error,reg_response;
    reg flag_response;
    wire flag_write,flag_read;
    assign o_wr_ready=!i_rst;
    assign o_rd_ready=!i_rst & !flag_response;
    assign o_rd_data=reg_response;
    assign o_rd_valid=!i_rst & flag_response;
    assign flag_write=i_wr_valid & o_wr_ready;
    assign flag_read=i_rd_valid & o_rd_ready;
    // 双字影子在显式提交时原子替换；零标记和不完整提交拒绝。
    always @(posedge i_clk) begin
        if(i_rst)begin reg_shadow<=64'd0;reg_active<=64'd0;reg_written<=2'd0;reg_error<=32'd0;end
        else if(flag_write)begin
            case(i_wr_addr)
                32'h18:begin reg_shadow[31:0]<=i_wr_data;reg_written[0]<=1'b1;end
                32'h1c:begin reg_shadow[63:32]<=i_wr_data;reg_written[1]<=1'b1;end
                32'h10:begin
                    if(i_wr_data!=32'd1 || reg_written!=2'b11 || reg_shadow==64'd0 || reg_error!=32'd0)begin reg_error<=32'd2;end
                    else begin reg_active<=reg_shadow;reg_written<=2'd0;end
                end
                default:begin reg_error<=32'd1;end
            endcase
        end
    end
    // 响应单槽保留；非法读返回GSNA，不别名到身份或标记。
    always @(posedge i_clk) begin
        if(i_rst)begin reg_response<=32'd0;flag_response<=1'b0;end
        else if(flag_read)begin
            flag_response<=1'b1;
            case(i_rd_addr)
                32'h00:reg_response<=32'h47534d34;
                32'h04:reg_response<=32'h00010004;
                32'h08:reg_response<=reg_active[31:0];
                32'h0c:reg_response<=reg_active[63:32];
                32'h10:reg_response<={30'd0,reg_written};
                32'h14:reg_response<=reg_error;
                32'h18:reg_response<=reg_shadow[31:0];
                32'h1c:reg_response<=reg_shadow[63:32];
                default:reg_response<=32'h47534e41;
            endcase
        end else if(i_rd_ready)begin flag_response<=1'b0;end
    end
endmodule
