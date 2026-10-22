`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/02 14:01:03
// Design Name:     gs_pdr_quality_compare
// Module Name:     gs_pdr_quality_compare
// Description:     gs_pdr_quality_compare_spec.md
// Simulations:     sim/tb_gs_pdr_quality_compare.v
//
// Referrences:     None
//
// Dependencies:    None
//
// Version:         V1.0
// Revision Date:   2026/10/02 14:01:03
// History:
// Time             Version     Revised by        Contents
// 2026/10/02       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月02日
// 设计名称:        gs_pdr_quality_compare
// 模块名称:        gs_pdr_quality_compare
// 模块说明:        gs_pdr_quality_compare_spec.md
// 仿真工程:        sim/tb_gs_pdr_quality_compare.v
//
// 参考资料:        None
//
// 依赖文件:        None
//
// 当前版本:        V1.0
// 修订日期:        2026年10月02日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月02日   V1.0        Relay project              创建文件

module gs_pdr_quality_compare
(
	//-----------------全局信号-----------------//
	input clk,                                  // 采样与流水推进时钟
	input rst,                                  // 同步高有效复位，冲刷在途事务

	//-----------------用户接口-----------------//

	//IN接口
	input in_valid,                             // 本沿输入事务有效
	input [15:0]in_tag,                         // 输入事务标识，随结果对齐
	input [8:0]in_count,                        // 当前窗口已结算包总数
	input [8:0]in_delivered,                    // 当前窗口已送达包数
	input [8:0]cfg_window,                      // 统计窗口容量上限
	input [8:0]cfg_min_count,                   // 参与判别所需最小样本量
	input [9:0]cfg_low,                         // 低质量阈值，单位千分比
	input [9:0]cfg_high,                        // 恢复侧阈值，单位千分比

	//OUT接口
	output out_valid,                           // 接收后第四周期结果有效
	output [15:0]out_tag,                       // 与质量结果对应的输入标识
	output [2:0]out_code                        // 数值质量及输入错误状态码
);

	//-----------------计数信号-----------------//
	reg cnt_error = 1'd0;                       // 总数或送达数的范围错误归并

	//----------------寄存器信号----------------//
	reg [15:0]reg_product_tag = 16'd0;          // 乘积级保存输入标识
	reg [15:0]reg_compare_tag = 16'd0;          // 比较级保持标识对应关系
	reg [15:0]reg_warm_tag = 16'd0;             // 质量编码阶段的事务标识
	reg [15:0]reg_empty_tag = 16'd0;            // 预热选择阶段的事务标识
	reg [18:0]reg_delivered_product = 19'd0;    // 送达数乘千分比例基数
	reg [18:0]reg_low_product = 19'd0;          // 低阈值与窗口计数乘积
	reg [18:0]reg_high_product = 19'd0;         // 高阈值与窗口计数乘积
	reg reg_error_window_zero = 1'd0;           // 窗口容量被配置为零
	reg reg_error_window_large = 1'd0;          // 窗口容量超过硬件支持的二百五十六项
	reg reg_error_minimum_zero = 1'd0;          // 最低样本门槛不能为零
	reg reg_error_minimum_large = 1'd0;         // 最低样本门槛超过配置容量
	reg reg_error_total_large = 1'd0;           // 结算计数超出窗口容量
	reg reg_error_delivered_large = 1'd0;       // 送达数大于全部结算数
	reg reg_error_threshold_order = 1'd0;       // 上下阈值未严格递增
	reg reg_error_threshold_large = 1'd0;       // 高阈值超过千分比上限
	reg reg_error_window = 1'd0;                // 窗口范围错误归并
	reg reg_error_minimum = 1'd0;               // 最低样本配置错误归并
	reg reg_error_threshold = 1'd0;             // 阈值范围与顺序错误归并
	reg reg_error_config = 1'd0;                // 窗口配置错误归并
	reg reg_error_data = 1'd0;                  // 数据和阈值错误归并
	reg reg_error_any = 1'd0;                   // 输出前汇总错误标记
	reg reg_product_empty = 1'd0;               // 空窗口预译码
	reg reg_product_warmup = 1'd0;              // 最小样本数未满足
	reg reg_compare_empty = 1'd0;               // 空窗口随乘法比较推进
	reg reg_compare_warmup = 1'd0;              // 样本预热随比较推进
	reg reg_warm_empty = 1'd0;                  // 空窗口随预热编码推进
	reg reg_compare_bad = 1'd0;                 // 精确比较低阈值含相等
	reg reg_compare_good = 1'd0;                // 精确比较高阈值含相等
	reg [2:0]reg_warm_quality = 3'd0;           // 低高阈值选择数值质量码
	reg reg_warm_warmup = 1'd0;                 // 样本不足条件对齐编码
	reg [2:0]reg_empty_code = 3'd0;             // 预热优先于数值质量

	//-----------------标志信号-----------------//
	reg flag_product_valid = 1'd0;              // 乘积级是否携带已接收事务
	reg flag_compare_valid = 1'd0;              // 比较级的事务有效性
	reg flag_warm_valid = 1'd0;                 // 数值编码级的有效标记
	reg flag_empty_valid = 1'd0;                // 预热编码级的有效标记
	reg flag_empty = 1'd0;                      // 空窗标记对齐末级

	//-----------------输出信号-----------------//
	//用户接口
	reg out_valid_o = 1'd0;                     // 末级寄存的结果有效脉冲
	reg [15:0]out_tag_o = 16'd0;                // 末级寄存的输入标签副本
	reg [2:0]out_code_o = 3'd0;                 // 非法优先、空窗其次的最终状态

	//---------------输出信号连线---------------//
	//用户接口
	assign out_valid = out_valid_o;             // 有效标记输出桥接
	assign out_tag = out_tag_o;                 // 事务标签输出桥接
	assign out_code = out_code_o;               // 质量状态输出桥接

	//-------------输出信号处理区域-------------//
	//用户接口
	// 将第四拍有效标记推进到结果端口。
	always@(posedge clk)begin
		if(rst)begin
			out_valid_o <= 1'd0;                // 复位时清除末级寄存的结果有效脉冲
		end else begin
			out_valid_o <= flag_empty_valid;    // 本时钟沿更新末级寄存的结果有效脉冲
		end
	end

	// 复制末级标签以标识当前输出所属事务。
	always@(posedge clk)begin
		if(rst)begin
			out_tag_o <= 16'd0;                 // 复位时清除末级寄存的输入标签副本
		end else begin
			out_tag_o <= reg_empty_tag;         // 本时钟沿更新末级寄存的输入标签副本
		end
	end

	// 寄存非法优先、空窗其次的最终状态。
	always@(posedge clk)begin
		if(rst)begin
			out_code_o <= 3'd0;                 // 复位时清除非法优先、空窗其次的最终状态
		end else begin
			out_code_o <= reg_error_any ? 3'd7 : (flag_empty ? 3'd0 : reg_empty_code); // 本时钟沿更新非法优先、空窗其次的最终状态
		end
	end

	//-------------主要任务处理区域-------------//
	// 寄存乘积级是否携带已接收事务。
	always@(posedge clk)begin
		if(rst)begin
			flag_product_valid <= 1'd0;         // 复位时清除乘积级是否携带已接收事务
		end else begin
			flag_product_valid <= in_valid;     // 本时钟沿更新乘积级是否携带已接收事务
		end
	end

	// 寄存乘积级保存输入标识。
	always@(posedge clk)begin
		if(rst)begin
			reg_product_tag <= 16'd0;           // 复位时清除乘积级保存输入标识
		end else begin
			reg_product_tag <= in_tag;          // 本时钟沿更新乘积级保存输入标识
		end
	end

	// 寄存送达数乘千分比例基数。
	always@(posedge clk)begin
		if(rst)begin
			reg_delivered_product <= 19'd0;     // 复位时清除送达数乘千分比例基数
		end else begin
			reg_delivered_product <= in_delivered * 10'd1000; // 本时钟沿更新送达数乘千分比例基数
		end
	end

	// 寄存低阈值与窗口计数乘积。
	always@(posedge clk)begin
		if(rst)begin
			reg_low_product <= 19'd0;           // 复位时清除低阈值与窗口计数乘积
		end else begin
			reg_low_product <= cfg_low * in_count; // 本时钟沿更新低阈值与窗口计数乘积
		end
	end

	// 寄存高阈值与窗口计数乘积。
	always@(posedge clk)begin
		if(rst)begin
			reg_high_product <= 19'd0;          // 复位时清除高阈值与窗口计数乘积
		end else begin
			reg_high_product <= cfg_high * in_count; // 本时钟沿更新高阈值与窗口计数乘积
		end
	end

	// 寄存窗口容量被配置为零。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_window_zero <= 1'd0;      // 复位时清除窗口容量被配置为零
		end else begin
			reg_error_window_zero <= cfg_window == 9'd0; // 本时钟沿更新窗口容量被配置为零
		end
	end

	// 在采样沿检测容量是否突破硬件上限。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_window_large <= 1'd0;     // 复位时清除窗口容量超过硬件支持的二百五十六项
		end else begin
			reg_error_window_large <= cfg_window > 9'd256; // 本时钟沿更新窗口容量超过硬件支持的二百五十六项
		end
	end

	// 寄存最低样本门槛不能为零。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_minimum_zero <= 1'd0;     // 复位时清除最低样本门槛不能为零
		end else begin
			reg_error_minimum_zero <= cfg_min_count == 9'd0; // 本时钟沿更新最低样本门槛不能为零
		end
	end

	// 寄存最低样本门槛超过配置容量。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_minimum_large <= 1'd0;    // 复位时清除最低样本门槛超过配置容量
		end else begin
			reg_error_minimum_large <= cfg_min_count > cfg_window; // 本时钟沿更新最低样本门槛超过配置容量
		end
	end

	// 寄存结算计数超出窗口容量。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_total_large <= 1'd0;      // 复位时清除结算计数超出窗口容量
		end else begin
			reg_error_total_large <= in_count > cfg_window; // 本时钟沿更新结算计数超出窗口容量
		end
	end

	// 寄存送达数大于全部结算数。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_delivered_large <= 1'd0;  // 复位时清除送达数大于全部结算数
		end else begin
			reg_error_delivered_large <= in_delivered > in_count; // 本时钟沿更新送达数大于全部结算数
		end
	end

	// 寄存上下阈值未严格递增。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_threshold_order <= 1'd0;  // 复位时清除上下阈值未严格递增
		end else begin
			reg_error_threshold_order <= cfg_low >= cfg_high; // 本时钟沿更新上下阈值未严格递增
		end
	end

	// 寄存高阈值超过千分比上限。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_threshold_large <= 1'd0;  // 复位时清除高阈值超过千分比上限
		end else begin
			reg_error_threshold_large <= cfg_high > 10'd1000; // 本时钟沿更新高阈值超过千分比上限
		end
	end

	// 寄存空窗口预译码。
	always@(posedge clk)begin
		if(rst)begin
			reg_product_empty <= 1'd0;          // 复位时清除空窗口预译码
		end else begin
			reg_product_empty <= in_count == 9'd0; // 本时钟沿更新空窗口预译码
		end
	end

	// 寄存最小样本数未满足。
	always@(posedge clk)begin
		if(rst)begin
			reg_product_warmup <= 1'd0;         // 复位时清除最小样本数未满足
		end else begin
			reg_product_warmup <= in_count < cfg_min_count; // 本时钟沿更新最小样本数未满足
		end
	end

	// 寄存比较级的事务有效性。
	always@(posedge clk)begin
		if(rst)begin
			flag_compare_valid <= 1'd0;         // 复位时清除比较级的事务有效性
		end else begin
			flag_compare_valid <= flag_product_valid; // 本时钟沿更新比较级的事务有效性
		end
	end

	// 寄存比较级保持标识对应关系。
	always@(posedge clk)begin
		if(rst)begin
			reg_compare_tag <= 16'd0;           // 复位时清除比较级保持标识对应关系
		end else begin
			reg_compare_tag <= reg_product_tag; // 本时钟沿更新比较级保持标识对应关系
		end
	end

	// 寄存窗口范围错误归并。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_window <= 1'd0;           // 复位时清除窗口范围错误归并
		end else begin
			reg_error_window <= reg_error_window_zero | reg_error_window_large; // 本时钟沿更新窗口范围错误归并
		end
	end

	// 寄存最低样本配置错误归并。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_minimum <= 1'd0;          // 复位时清除最低样本配置错误归并
		end else begin
			reg_error_minimum <= reg_error_minimum_zero | reg_error_minimum_large; // 本时钟沿更新最低样本配置错误归并
		end
	end

	// 寄存总数或送达数的范围错误归并。
	always@(posedge clk)begin
		if(rst)begin
			cnt_error <= 1'd0;                  // 复位时清除总数或送达数的范围错误归并
		end else begin
			cnt_error <= reg_error_total_large | reg_error_delivered_large; // 本时钟沿更新总数或送达数的范围错误归并
		end
	end

	// 寄存阈值范围与顺序错误归并。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_threshold <= 1'd0;        // 复位时清除阈值范围与顺序错误归并
		end else begin
			reg_error_threshold <= reg_error_threshold_order | reg_error_threshold_large; // 本时钟沿更新阈值范围与顺序错误归并
		end
	end

	// 寄存空窗口随乘法比较推进。
	always@(posedge clk)begin
		if(rst)begin
			reg_compare_empty <= 1'd0;          // 复位时清除空窗口随乘法比较推进
		end else begin
			reg_compare_empty <= reg_product_empty; // 本时钟沿更新空窗口随乘法比较推进
		end
	end

	// 寄存样本预热随比较推进。
	always@(posedge clk)begin
		if(rst)begin
			reg_compare_warmup <= 1'd0;         // 复位时清除样本预热随比较推进
		end else begin
			reg_compare_warmup <= reg_product_warmup; // 本时钟沿更新样本预热随比较推进
		end
	end

	// 寄存精确比较低阈值含相等。
	always@(posedge clk)begin
		if(rst)begin
			reg_compare_bad <= 1'd0;            // 复位时清除精确比较低阈值含相等
		end else begin
			reg_compare_bad <= (reg_delivered_product <= reg_low_product); // 本时钟沿更新精确比较低阈值含相等
		end
	end

	// 寄存精确比较高阈值含相等。
	always@(posedge clk)begin
		if(rst)begin
			reg_compare_good <= 1'd0;           // 复位时清除精确比较高阈值含相等
		end else begin
			reg_compare_good <= (reg_delivered_product >= reg_high_product); // 本时钟沿更新精确比较高阈值含相等
		end
	end

	// 寄存数值编码级的有效标记。
	always@(posedge clk)begin
		if(rst)begin
			flag_warm_valid <= 1'd0;            // 复位时清除数值编码级的有效标记
		end else begin
			flag_warm_valid <= flag_compare_valid; // 本时钟沿更新数值编码级的有效标记
		end
	end

	// 寄存质量编码阶段的事务标识。
	always@(posedge clk)begin
		if(rst)begin
			reg_warm_tag <= 16'd0;              // 复位时清除质量编码阶段的事务标识
		end else begin
			reg_warm_tag <= reg_compare_tag;    // 本时钟沿更新质量编码阶段的事务标识
		end
	end

	// 寄存窗口配置错误归并。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_config <= 1'd0;           // 复位时清除窗口配置错误归并
		end else begin
			reg_error_config <= reg_error_window | reg_error_minimum; // 本时钟沿更新窗口配置错误归并
		end
	end

	// 寄存数据和阈值错误归并。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_data <= 1'd0;             // 复位时清除数据和阈值错误归并
		end else begin
			reg_error_data <= cnt_error | reg_error_threshold; // 本时钟沿更新数据和阈值错误归并
		end
	end

	// 寄存空窗口随预热编码推进。
	always@(posedge clk)begin
		if(rst)begin
			reg_warm_empty <= 1'd0;             // 复位时清除空窗口随预热编码推进
		end else begin
			reg_warm_empty <= reg_compare_empty; // 本时钟沿更新空窗口随预热编码推进
		end
	end

	// 寄存低高阈值选择数值质量码。
	always@(posedge clk)begin
		if(rst)begin
			reg_warm_quality <= 3'd0;           // 复位时清除低高阈值选择数值质量码
		end else begin
			reg_warm_quality <= reg_compare_bad ? 2'd2 : (reg_compare_good ? 3'd4 : 2'd3); // 本时钟沿更新低高阈值选择数值质量码
		end
	end

	// 寄存样本不足条件对齐编码。
	always@(posedge clk)begin
		if(rst)begin
			reg_warm_warmup <= 1'd0;            // 复位时清除样本不足条件对齐编码
		end else begin
			reg_warm_warmup <= reg_compare_warmup; // 本时钟沿更新样本不足条件对齐编码
		end
	end

	// 寄存预热编码级的有效标记。
	always@(posedge clk)begin
		if(rst)begin
			flag_empty_valid <= 1'd0;           // 复位时清除预热编码级的有效标记
		end else begin
			flag_empty_valid <= flag_warm_valid; // 本时钟沿更新预热编码级的有效标记
		end
	end

	// 寄存预热选择阶段的事务标识。
	always@(posedge clk)begin
		if(rst)begin
			reg_empty_tag <= 16'd0;             // 复位时清除预热选择阶段的事务标识
		end else begin
			reg_empty_tag <= reg_warm_tag;      // 本时钟沿更新预热选择阶段的事务标识
		end
	end

	// 寄存输出前汇总错误标记。
	always@(posedge clk)begin
		if(rst)begin
			reg_error_any <= 1'd0;              // 复位时清除输出前汇总错误标记
		end else begin
			reg_error_any <= reg_error_config | reg_error_data; // 本时钟沿更新输出前汇总错误标记
		end
	end

	// 寄存预热优先于数值质量。
	always@(posedge clk)begin
		if(rst)begin
			reg_empty_code <= 3'd0;             // 复位时清除预热优先于数值质量
		end else begin
			reg_empty_code <= reg_warm_warmup ? 1'd1 : reg_warm_quality; // 本时钟沿更新预热优先于数值质量
		end
	end

	// 寄存空窗标记对齐末级。
	always@(posedge clk)begin
		if(rst)begin
			flag_empty <= 1'd0;                 // 复位时清除空窗标记对齐末级
		end else begin
			flag_empty <= reg_warm_empty;       // 本时钟沿更新空窗标记对齐末级
		end
	end

endmodule
