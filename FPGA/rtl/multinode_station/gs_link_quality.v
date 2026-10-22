`timescale 1ns / 1ps
// PDR、RTT与AoI的必需指标合成；固定延迟事件，不自行续期。
module gs_link_quality(
    input i_clk, // 唯一上升沿时钟，目标200MHz
    input i_rst, // 同步高复位取消全部在途评估
    input i_valid, // 当沿提交一个完整评估事务
    input [31:0] i_tag, // 调用方事务标签，不解释为时间
    input [1:0] i_pdr, // 已经资格化的PDR条件
    input [2:0] i_required, // 位零PDR必须为一，位一RTT，位二AoI
    input i_rtt_available, // RTT来源及时间资格
    input [63:0] i_rtt_lower, // RTT区间下界
    input [63:0] i_rtt_upper, // RTT区间上界
    input [63:0] i_rtt_good, // RTT好质量上边界
    input [63:0] i_rtt_bad, // RTT坏质量下边界
    input i_aoi_available, // AoI来源及时间映射资格
    input [63:0] i_aoi_lower, // AoI区间下界
    input [63:0] i_aoi_upper, // AoI区间上界
    input [63:0] i_aoi_good, // AoI好质量上边界
    input [63:0] i_aoi_bad, // AoI坏质量下边界
    output o_valid, // 接受沿后第四沿输出评估事件
    output [31:0] o_tag, // 与输入同笔的事务标签
    output [1:0] o_condition, // 合成条件：零不可用，一BAD，二BAND，三GOOD
    output [2:0] o_missing, // 不可用且被要求的指标掩码
    output o_invalid, // required非法，不允许省略PDR
    output [1:0] o_rtt_condition, // 同笔RTT分类
    output [1:0] o_rtt_reason, // 同笔RTT不可用原因
    output [1:0] o_aoi_condition, // 同笔AoI分类
    output [1:0] o_aoi_reason // 同笔AoI不可用原因
);
    wire flag_rtt_valid,flag_aoi_valid; // 两个数值流水的同行资格
    wire [1:0] reg_rtt_condition,reg_rtt_reason; // RTT分类器输出
    wire [1:0] reg_aoi_condition,reg_aoi_reason; // AoI分类器输出
    reg [127:0] reg_tag; // 四个完整标签流水层
    reg [7:0] reg_pdr; // 四个PDR条件流水层
    reg [11:0] reg_required; // 四个策略掩码流水层
    wire [2:0] flag_missing; // 末级必需指标缺失资格
    wire [2:0] flag_bad; // 末级必需指标BAD资格
    wire [2:0] flag_band; // 末级必需指标BAND资格
    reg flag_valid_o; // 输出事件资格寄存器
    reg [31:0] reg_tag_o; // 输出事务标签寄存器
    reg [1:0] reg_condition_o; // 合成条件寄存器
    reg [2:0] reg_missing_o; // 缺失掩码寄存器
    reg flag_invalid_o; // 掩码非法寄存器
    reg [3:0] reg_rtt_o; // RTT条件及原因不可拆分记录
    reg [3:0] reg_aoi_o; // AoI条件及原因不可拆分记录
    assign o_valid=flag_valid_o;
    assign o_tag=reg_tag_o;
    assign o_condition=reg_condition_o;
    assign o_missing=reg_missing_o;
    assign o_invalid=flag_invalid_o;
    assign o_rtt_condition=reg_rtt_o[3:2];
    assign o_rtt_reason=reg_rtt_o[1:0];
    assign o_aoi_condition=reg_aoi_o[3:2];
    assign o_aoi_reason=reg_aoi_o[1:0];
    assign flag_missing[0]=reg_required[9] & (reg_pdr[7:6]==2'd0);
    assign flag_missing[1]=reg_required[10] & (reg_rtt_condition==2'd0);
    assign flag_missing[2]=reg_required[11] & (reg_aoi_condition==2'd0);
    assign flag_bad[0]=reg_required[9] & (reg_pdr[7:6]==2'd1);
    assign flag_bad[1]=reg_required[10] & (reg_rtt_condition==2'd1);
    assign flag_bad[2]=reg_required[11] & (reg_aoi_condition==2'd1);
    assign flag_band[0]=reg_required[9] & (reg_pdr[7:6]==2'd2);
    assign flag_band[1]=reg_required[10] & (reg_rtt_condition==2'd2);
    assign flag_band[2]=reg_required[11] & (reg_aoi_condition==2'd2);
    gs_interval_quality Rtt_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_available(i_rtt_available),
        .i_lower(i_rtt_lower),.i_upper(i_rtt_upper),.i_good(i_rtt_good),.i_bad(i_rtt_bad),
        .o_valid(flag_rtt_valid),.o_condition(reg_rtt_condition),.o_reason(reg_rtt_reason));
    gs_interval_quality Aoi_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_available(i_aoi_available),
        .i_lower(i_aoi_lower),.i_upper(i_aoi_upper),.i_good(i_aoi_good),.i_bad(i_aoi_bad),
        .o_valid(flag_aoi_valid),.o_condition(reg_aoi_condition),.o_reason(reg_aoi_reason));
    always @(posedge i_clk) begin
        if(i_rst) begin
            reg_tag<=128'd0;
            reg_pdr<=8'd0;
            reg_required<=12'd0;
        end else begin
            reg_tag<={reg_tag[95:0],i_tag};
            reg_pdr<={reg_pdr[5:0],i_pdr};
            reg_required<={reg_required[8:0],i_required};
        end
    end
    always @(posedge i_clk) begin
        if(i_rst) begin
            flag_valid_o<=1'b0;
            reg_tag_o<=32'd0;
            reg_condition_o<=2'd0;
            reg_missing_o<=3'd0;
            flag_invalid_o<=1'b0;
            reg_rtt_o<=4'd0;
            reg_aoi_o<=4'd0;
        end else begin
            flag_valid_o<=flag_rtt_valid & flag_aoi_valid;
            reg_tag_o<=reg_tag[127:96];
            reg_missing_o<=flag_missing;
            flag_invalid_o<=(!reg_required[9]);
            reg_rtt_o<={reg_rtt_condition,reg_rtt_reason};
            reg_aoi_o<={reg_aoi_condition,reg_aoi_reason};
            if((!reg_required[9]) | (|flag_missing)) begin
                reg_condition_o<=2'd0;
            end else if(|flag_bad) begin
                reg_condition_o<=2'd1;
            end else if(|flag_band) begin
                reg_condition_o<=2'd2;
            end else begin
                reg_condition_o<=2'd3;
            end
        end
    end
endmodule
