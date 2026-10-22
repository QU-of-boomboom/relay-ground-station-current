`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/02 20:15:21
// Design Name:     gs_quality_context
// Module Name:     gs_quality_context
// Description:     gs_quality_context_spec.md
// Simulations:     sim/tb_gs_quality_context.v
//
// Referrences:     None
//
// Dependencies:    None
//
// Version:         V1.0
// Revision Date:   2026/10/02 20:15:21
// History:
// Time             Version     Revised by        Contents
// 2026/10/02       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月02日
// 设计名称:        gs_quality_context
// 模块名称:        gs_quality_context
// 模块说明:        gs_quality_context_spec.md
// 仿真工程:        sim/tb_gs_quality_context.v
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

module gs_quality_context
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 本地时钟
	input i_rst,                                // 同步高有效复位
	input i_clear,                              // 同步提交冲刷

	//-----------------用户接口-----------------//
	input i_valid,                              // 本拍事务有效
	input [15:0]i_tag,                          // 核心对齐标签
	input [8:0]i_count,                         // 统计包数
	input [8:0]i_delivered,                     // 送达包数
	input [8:0]i_window,                        // 窗口容量
	input [8:0]i_minimum,                       // 最少有效样本量
	input [9:0]i_low,                           // 低质量阈值
	input [9:0]i_high,                          // 恢复质量阈值
	input [353:0]i_context,                     // 完整绑定上下文
	output o_valid,                             // 结果有效
	output [15:0]o_tag,                         // 返回标签
	output [2:0]o_code,                         // 数值质量码
	output [353:0]o_context                     // 结果对应的原上下文
);

	//--------------模块实例化信号--------------//
	// 共享给数值核心的同步控制
	wire flush;                                 // 统一同步冲刷条件

	//----------------寄存器信号----------------//
	reg [353:0]reg_context_first = 354'd0;      // 接收沿保存原始证据字段
	reg [353:0]reg_context_second = 354'd0;     // 乘积比较阶段的绑定副本
	reg [353:0]reg_context_third = 354'd0;      // 数值编码阶段对应的身份记录
	reg [353:0]reg_context_fourth = 354'd0;     // 输出选择前一级的来源记录

	//-----------------输出信号-----------------//
	//用户接口
	wire valid_o;                               // 数值核心有效标记
	wire [15:0]tag_o;                           // 数值核心事务标签
	wire [2:0]code_o;                           // 数值核心质量编码
	reg [353:0]context_o = 354'd0;              // 结果沿提供给消费者的完整证据

	//---------------其他信号连线---------------//
	//其他信号连线
	assign flush = i_rst | i_clear;             // 提交和复位优先于输入

	//---------------输出信号连线---------------//
	//用户接口
	assign o_valid = valid_o;                   // 显式连接子模块有效输出
	assign o_tag = tag_o;                       // 返回当前结果标签，不增加寄存级
	assign o_code = code_o;                     // 返回当前质量码，保持E+4
	assign o_context = context_o;               // 与数值核心E+4输出同沿

	//-------------输出信号处理区域-------------//
	//用户接口
	// 将证据提交到输出端，与有效质量码同周期。
	always@(posedge i_clk)begin
		if(flush == 1'b1)begin
			context_o <= 354'd0;                // 阻止冲刷前事务在输出沿重新出现
		end else begin
			context_o <= reg_context_fourth;    // 在接收后第四周期提交同笔上下文
		end
	end

	//-------------主要任务处理区域-------------//
	// 接收当前事务元数据，复位与提交优先清除。
	always@(posedge i_clk)begin
		if(flush == 1'b1)begin
			reg_context_first <= 354'd0;        // 丢弃接收沿刚进入的上下文
		end else begin
			reg_context_first <= i_context;     // 捕获本次输入的完整身份及证据字段
		end
	end

	// 对齐乘法后比较阶段，保留全部字段。
	always@(posedge i_clk)begin
		if(flush == 1'b1)begin
			reg_context_second <= 354'd0;       // 清除比较阶段对应的身份信息
		end else begin
			reg_context_second <= reg_context_first; // 将输入证据随乘积比较向后推进
		end
	end

	// 推进与质量编码配套的身份和来源时刻。
	always@(posedge i_clk)begin
		if(flush == 1'b1)begin
			reg_context_third <= 354'd0;        // 清除数值编码阶段的绑定记录
		end else begin
			reg_context_third <= reg_context_second; // 保持证据与数值编码阶段对应
		end
	end

	// 将错误及预热选择阶段的记录送往末级。
	always@(posedge i_clk)begin
		if(flush == 1'b1)begin
			reg_context_fourth <= 354'd0;       // 撤销输出前一级的证据元数据
		end else begin
			reg_context_fourth <= reg_context_third; // 对齐预热编码和错误归并阶段
		end
	end

	//--------------模块实例化区域--------------//
	//实际数值运算，不由包装器复制算法
	gs_pdr_quality_compare gs_pdr_quality_compare_Inst_quality( // 使用既有数值比较流水
		.clk(i_clk),                            // 统一本地采样时钟
		.rst(flush),                            // 同步复位和提交冲刷
		.in_valid(i_valid),                     // 同拍接受标记
		.in_tag(i_tag),                         // 原事务标签
		.in_count(i_count),                     // 当前统计总量
		.in_delivered(i_delivered),             // 当前送达量
		.cfg_window(i_window),                  // 随事务捕获的窗口配置
		.cfg_min_count(i_minimum),              // 最少样本配置
		.cfg_low(i_low),                        // 低质量门限
		.cfg_high(i_high),                      // 恢复门限
		.out_valid(valid_o),                    // 子模块寄存有效位的真实驱动
		.out_tag(tag_o),                        // 子模块标签输出的真实驱动
		.out_code(code_o)                       // 子模块质量码输出的真实驱动
	);

endmodule
