`timescale 1ns / 1ps
// 分段无符号比较；三个寄存器层，避免64位串联进位路径。
module gs_unsigned_compare(
    input i_clk, // 唯一上升沿时钟
    input i_rst, // 同步高复位，取消在途比较
    input i_valid, // 当沿接受完整比较操作数
    input [63:0] i_left, // 无符号左操作数
    input [63:0] i_right, // 无符号右操作数
    output o_valid, // 接受沿后第二沿给出有效结果
    output o_less, // 左操作数严格小于右操作数
    output o_equal // 两个操作数完全相等
);
    reg [3:0] reg_chunk_less; // 四个16位区段的比较结果
    reg [3:0] reg_chunk_equal; // 四个16位区段的相等资格
    reg [1:0] reg_pair_less; // 两个32位区段的小于结果
    reg [1:0] reg_pair_equal; // 两个32位区段的相等资格
    reg [2:0] reg_valid; // 与三个比较层同行的事务资格
    reg flag_less_o; // 最终64位小于结果寄存器
    reg flag_equal_o; // 最终64位相等结果寄存器
    genvar gen_chunk; // 固定四段的静态展开索引
    assign o_valid=reg_valid[2];
    assign o_less=flag_less_o;
    assign o_equal=flag_equal_o;
    always @(posedge i_clk) begin
        if(i_rst) begin
            reg_valid<=3'd0;
        end else begin
            reg_valid<={reg_valid[1:0],i_valid};
        end
    end
    generate
        for(gen_chunk=0;gen_chunk<4;gen_chunk=gen_chunk+1) begin:gen_compare
            always @(posedge i_clk) begin
                if(i_rst) begin
                    reg_chunk_less[gen_chunk]<=1'b0;
                    reg_chunk_equal[gen_chunk]<=1'b0;
                end else begin
                    reg_chunk_less[gen_chunk]<=(i_left[gen_chunk*16 +: 16]<i_right[gen_chunk*16 +: 16]);
                    reg_chunk_equal[gen_chunk]<=(i_left[gen_chunk*16 +: 16]==i_right[gen_chunk*16 +: 16]);
                end
            end
        end
    endgenerate
    always @(posedge i_clk) begin
        if(i_rst) begin
            reg_pair_less<=2'd0;
            reg_pair_equal<=2'd0;
        end else begin
            reg_pair_less[0]<=reg_chunk_less[1] | (reg_chunk_equal[1] & reg_chunk_less[0]);
            reg_pair_less[1]<=reg_chunk_less[3] | (reg_chunk_equal[3] & reg_chunk_less[2]);
            reg_pair_equal[0]<=reg_chunk_equal[1] & reg_chunk_equal[0];
            reg_pair_equal[1]<=reg_chunk_equal[3] & reg_chunk_equal[2];
        end
    end
    always @(posedge i_clk) begin
        if(i_rst) begin
            flag_less_o<=1'b0;
            flag_equal_o<=1'b0;
        end else begin
            flag_less_o<=reg_pair_less[1] | (reg_pair_equal[1] & reg_pair_less[0]);
            flag_equal_o<=reg_pair_equal[1] & reg_pair_equal[0];
        end
    end
endmodule
