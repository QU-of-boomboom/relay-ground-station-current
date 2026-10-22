`timescale 1ns / 1ps
// 可信时间域中的区间分类；输入资格不能由本算子猜测。
module gs_interval_quality(
    input i_clk, // 唯一上升沿时钟
    input i_rst, // 同步高复位取消在途记录
    input i_valid, // 接受完整区间与策略
    input i_available, // 外部已确认来源新鲜及时间域有效
    input [63:0] i_lower, // 区间下界，单位与阈值相同
    input [63:0] i_upper, // 区间上界，不得小于下界
    input [63:0] i_good, // GOOD包含的上边界
    input [63:0] i_bad, // BAD包含的下边界，必须大于good
    output o_valid, // 接受沿后第三沿分类有效
    output [1:0] o_condition, // 零不可用，一BAD，二BAND，三GOOD
    output [1:0] o_reason // 零可用，一非法，二来源不可用，三跨阈值
);
    wire [5:0] flag_compare_valid; // 六个比较器同拍输出资格
    wire [5:0] flag_compare_less; // 顺序为区间、策略、好界、坏界、下中界、上中界
    wire [5:0] flag_compare_equal; // 各比较的相等结果
    reg [2:0] reg_available; // 与三个比较层同行的来源资格
    reg flag_valid_o; // 分类结果事件资格
    reg [1:0] reg_condition_o; // 分类编码寄存器
    reg [1:0] reg_reason_o; // 不可用原因寄存器
    wire flag_bounds_legal; // 下界不高于上界
    wire flag_good; // 上界不高于GOOD门限
    wire flag_bad; // 下界不低于BAD门限
    wire flag_band; // 整个区间严格处于两门限之间
    assign o_valid=flag_valid_o;
    assign o_condition=reg_condition_o;
    assign o_reason=reg_reason_o;
    assign flag_bounds_legal=flag_compare_less[0] | flag_compare_equal[0];
    assign flag_good=flag_compare_less[2] | flag_compare_equal[2];
    assign flag_bad=(!flag_compare_less[3]);
    assign flag_band=flag_compare_less[4] & flag_compare_less[5];
    gs_unsigned_compare Bounds_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_lower),.i_right(i_upper),
        .o_valid(flag_compare_valid[0]),.o_less(flag_compare_less[0]),.o_equal(flag_compare_equal[0]));
    gs_unsigned_compare Policy_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_good),.i_right(i_bad),
        .o_valid(flag_compare_valid[1]),.o_less(flag_compare_less[1]),.o_equal(flag_compare_equal[1]));
    gs_unsigned_compare Good_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_upper),.i_right(i_good),
        .o_valid(flag_compare_valid[2]),.o_less(flag_compare_less[2]),.o_equal(flag_compare_equal[2]));
    gs_unsigned_compare Bad_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_lower),.i_right(i_bad),
        .o_valid(flag_compare_valid[3]),.o_less(flag_compare_less[3]),.o_equal(flag_compare_equal[3]));
    gs_unsigned_compare LowerBand_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_good),.i_right(i_lower),
        .o_valid(flag_compare_valid[4]),.o_less(flag_compare_less[4]),.o_equal(flag_compare_equal[4]));
    gs_unsigned_compare UpperBand_Inst(.i_clk(i_clk),.i_rst(i_rst),.i_valid(i_valid),.i_left(i_upper),.i_right(i_bad),
        .o_valid(flag_compare_valid[5]),.o_less(flag_compare_less[5]),.o_equal(flag_compare_equal[5]));
    always @(posedge i_clk) begin
        if(i_rst) begin
            reg_available<=3'd0;
        end else begin
            reg_available<={reg_available[1:0],i_available};
        end
    end
    always @(posedge i_clk) begin
        if(i_rst) begin
            flag_valid_o<=1'b0;
            reg_condition_o<=2'd0;
            reg_reason_o<=2'd2;
        end else begin
            flag_valid_o<=(&flag_compare_valid);
            reg_condition_o<=2'd0;
            reg_reason_o<=2'd0;
            if((!flag_bounds_legal) | (!flag_compare_less[1])) begin
                reg_reason_o<=2'd1;
            end else if(!reg_available[2]) begin
                reg_reason_o<=2'd2;
            end else if(flag_good) begin
                reg_condition_o<=2'd3;
            end else if(flag_bad) begin
                reg_condition_o<=2'd1;
            end else if(flag_band) begin
                reg_condition_o<=2'd2;
            end else begin
                reg_reason_o<=2'd3;
            end
        end
    end
endmodule
