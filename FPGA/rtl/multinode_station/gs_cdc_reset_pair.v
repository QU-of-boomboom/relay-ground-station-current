`timescale 1ns / 1ps
// 两个原始复位分别同步释放，禁止把异步来源先组合再送同步器。
module gs_cdc_reset_pair (
    input i_src_clk, // 请求来源域时钟
    input i_src_rstn, // 来源域原始低复位
    input i_dst_clk, // 执行端时钟
    input i_dst_rstn, // 目标域原始低复位
    output o_src_run, // 来源域共同释放资格
    output o_dst_run // 目标域共同释放资格
);
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reg_src_local;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reg_src_peer;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reg_dst_local;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reg_dst_peer;
    // 来源复位在来源域释放。
    always @(posedge i_src_clk or negedge i_src_rstn) begin
        if(!i_src_rstn) begin reg_src_local<=2'd0; end
        else begin reg_src_local<={reg_src_local[0],1'b1}; end
    end
    // 目标复位在来源域释放。
    always @(posedge i_src_clk or negedge i_dst_rstn) begin
        if(!i_dst_rstn) begin reg_src_peer<=2'd0; end
        else begin reg_src_peer<={reg_src_peer[0],1'b1}; end
    end
    // 目标复位在执行域释放。
    always @(posedge i_dst_clk or negedge i_dst_rstn) begin
        if(!i_dst_rstn) begin reg_dst_local<=2'd0; end
        else begin reg_dst_local<={reg_dst_local[0],1'b1}; end
    end
    // 来源复位在执行域释放。
    always @(posedge i_dst_clk or negedge i_src_rstn) begin
        if(!i_src_rstn) begin reg_dst_peer<=2'd0; end
        else begin reg_dst_peer<={reg_dst_peer[0],1'b1}; end
    end
    assign o_src_run=reg_src_local[1] & reg_src_peer[1];
    assign o_dst_run=reg_dst_local[1] & reg_dst_peer[1];
endmodule
