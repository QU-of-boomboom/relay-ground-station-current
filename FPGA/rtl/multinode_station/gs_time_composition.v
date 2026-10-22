`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/03 14:36:36
// Design Name:     gs_time_composition
// Module Name:     gs_time_composition
// Description:     gs_time_composition_spec.md
// Simulations:     sim/tb_gs_time_composition.v
//
// Referrences:     None
//
// Dependencies:    gs_time_freshness.v, gs_quality_composition.v
//
// Version:         V1.0
// Revision Date:   2026/10/03 14:36:36
// History:
// Time             Version     Revised by        Contents
// 2026/10/03       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月03日
// 设计名称:        gs_time_composition
// 模块名称:        gs_time_composition
// 模块说明:        gs_time_composition_spec.md
// 仿真工程:        sim/tb_gs_time_composition.v
//
// 参考资料:        None
//
// 依赖文件:        gs_time_freshness.v, gs_quality_composition.v
//
// 当前版本:        V1.0
// 修订日期:        2026年10月03日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月03日   V1.0        Relay project              创建文件

module gs_time_composition
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 单域流水时钟
	input i_rst,                                // 同步高有效复位
	input i_clear,                              // 冲刷全部在途及同沿输入
	//-----------------用户接口-----------------//
	input i_valid,                              // 事务有效，独立于证据存在
	input [2:0] i_quality,                      // 已冻结数值质量
	input [1:0] i_binding,                      // 已冻结身份配置判定
	input i_global_invalid,                     // 前置控制参数非法
	input i_evidence_present,                   // 持有统计证据
	input [15:0] i_tag,                         // 可重复诊断标签
	input [353:0] i_context,                    // 原来源快照，低二位为时间已知和更新成功
	input [63:0] i_now_ms,                      // 原事务评估时刻
	input [63:0] i_max_age_ms,                  // 原事务过期阈值
	output o_valid,                             // T+10结果事务有效
	output [3:0] o_reason,                      // 优先级原因
	output [2:0] o_condition,                   // 合成语义条件
	output o_usable,                            // 数值是否可使用
	output [15:0] o_tag,                        // 原事务标签
	output [353:0] o_context,                   // 原来源快照
	output [63:0] o_evaluated_ms                // 原评估时刻
);
	//--------------模块实例化信号--------------//
	wire [15:0] wire_time_tag;                  // 时间核独立诊断标签
	wire [1:0] wire_time_status;                // 来源时间四态判定
	wire [63:0] wire_time_evaluated;            // 时间核返回采样时刻
	wire [63:0] wire_age;                       // 独立年龄，本接口不消费

	//----------------寄存器信号----------------//
	reg [377:0] reg_side_first;                 // 入口采样的全部旁路字段
	reg [377:0] reg_side_second;                // 年龄减法阶段保留的原始事务
	reg [377:0] reg_side_third;                 // 阈值比较时对应的来源信息
	reg [377:0] reg_side_fourth;                // 时间编码前一级的身份记录
	reg [377:0] reg_side_fifth;                 // 与时间核输出同沿的合成输入
	//-----------------标志信号-----------------//
	wire flag_time_valid;                       // 时间核输出事务有效
	wire flag_age_valid;                        // 独立年龄有效性，本接口不消费
	//-----------------其他信号-----------------//
	// 旁路同步控制
	wire wire_flush;                            // 旁路同步冲刷
	//-----------------输出信号-----------------//
	//用户接口
	wire valid_o;                               // 合成流水的最终有效标记
	wire [3:0] reason_o;                        // 最高优先级拒绝或质量原因
	wire [2:0] condition_o;                     // 送往告警适配的语义分类
	wire usable_o;                              // 允许使用本次数值判定
	wire [15:0] tag_o;                          // 随结果到达的诊断标识
	wire [353:0] context_o;                     // 完整354位来源与身份记录
	wire [63:0] evaluated_ms_o;                 // 当次判定的原始采样时刻
	//---------------其他信号连线---------------//
	assign wire_flush = i_rst | i_clear;        // 同沿输入不进入旁路
	//---------------输出信号连线---------------//
	//用户接口
	assign o_valid = valid_o;                   // 公布包含拒绝结果的事务
	assign o_reason = reason_o;                 // 输出最终选定的原因编码
	assign o_condition = condition_o;           // 提供后续状态机使用的条件
	assign o_usable = usable_o;                 // 标识BAD、BAND或GOOD可被消费
	assign o_tag = tag_o;                       // 不增加延迟地返回原标签
	assign o_context = context_o;               // 传递同一事务的全部证据位
	assign o_evaluated_ms = evaluated_ms_o;     // 保留时间计算使用的毫秒基准
	//-------------主要任务处理区域-------------//
	// 捕获事务控制、来源和诊断标签。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_first <= 378'd0;           // 清空入口捕获槽
		end else begin
			reg_side_first <= {i_valid, i_quality, i_binding, i_global_invalid, i_evidence_present, i_tag, i_context}; // 捕获当前控制和全部证据字段
		end
	end

	// 随年龄运算推进身份及数值分类。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_second <= 378'd0;          // 撤销时间运算第二拍的来源快照
		end else begin
			reg_side_second <= reg_side_first;  // 跟随年龄运算推进到第二级
		end
	end

	// 保留时间阈值判断所需的原始证据。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_third <= 378'd0;           // 丢弃阈值比较拍对应的证据
		end else begin
			reg_side_third <= reg_side_second;  // 对齐时间阈值比较的事务
		end
	end

	// 使旁路记录跟随时间状态编码。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_fourth <= 378'd0;          // 清除时间编码前的旁路记录
		end else begin
			reg_side_fourth <= reg_side_third;  // 随新鲜度状态编码推进来源记录
		end
	end

	// 向下游提供与时间结果同拍的完整输入。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_fifth <= 378'd0;           // 阻止旧事务从末级重新提交
		end else begin
			reg_side_fifth <= reg_side_fourth;  // 保持T+4时间结果与快照同沿
		end
	end
	//--------------模块实例化区域--------------//
	// 判定来源时间并返回独立标签。
	gs_time_freshness Time_Inst(                // 五级来源时间流水
		.i_clk(i_clk),                          // 共用本地采样时钟
		.i_rst(i_rst),                          // 同步复位覆盖全部流水
		.i_clear(i_clear),                      // 撤销当前及在途事务
		.i_valid(i_valid),                      // 接受对应周期的事务有效位
		.i_tag(i_tag),                          // 沿数据路径传递诊断标签
		.i_now_ms(i_now_ms),                    // 冻结的原始评估时刻
		.i_observation_ms(i_context[65:2]),     // 来源证据中的毫秒时间
		.i_max_age_ms(i_max_age_ms),            // 本次事务的过期阈值
		.i_time_known(i_context[1]),            // 来源时间已知标记
		.o_valid(flag_time_valid),              // 计算结果可消费标记
		.o_tag(wire_time_tag),                  // 返回同笔事务标签
		.o_status(wire_time_status),            // 新鲜或拒绝的四态编码
		.o_age_valid(flag_age_valid),           // 独立年龄有效性供诊断
		.o_age_ms(wire_age),                    // 独立年龄数值不进入合成ABI
		.o_evaluated_ms(wire_time_evaluated)    // 返回原始评估时刻
	);

	// 消费时间结果与同笔旁路快照。
	gs_quality_composition Composition_Inst(    // T+5接收，T+10提交
		.i_clk(i_clk),                          // 驱动优先树的公共时钟
		.i_rst(i_rst),                          // 复位合成结果及内部选择树
		.i_clear(i_clear),                      // 冲刷六级优先级流水
		.i_valid(flag_time_valid),              // 在T+5接受上游计算结果
		.i_quality(reg_side_fifth[376:374]),    // 延迟五级后的数值判定
		.i_binding(reg_side_fifth[373:372]),    // 同笔身份与配置判定
		.i_time_status(wire_time_status),       // 时间核心的已寄存分类
		.i_update_ok(reg_side_fifth[0]),        // 上下文最低位的更新结果
		.i_global_invalid(reg_side_fifth[371]), // 冻结控制参数合法性
		.i_evidence_present(reg_side_fifth[370]), // 证据是否存在而非事务有效
		.i_tag(reg_side_fifth[369:354]),        // 第五级旁路中的对应标签
		.i_context(reg_side_fifth[353:0]),      // 完整来源快照保持不变
		.i_evaluated_ms(wire_time_evaluated),   // 与旁路对应的原评估时间
		.o_valid(valid_o),                      // T+10输出已完成判断的事务
		.o_reason(reason_o),                    // 按优先级选择的完整原因
		.o_condition(condition_o),              // 用于后续告警适配的条件
		.o_usable(usable_o),                    // 仅数值质量状态可用
		.o_tag(tag_o),                          // 核对最终结果与源事务的关系
		.o_context(context_o),                  // 交付完整身份及来源快照
		.o_evaluated_ms(evaluated_ms_o)         // 交付结果所属的历史评估时刻
	);
endmodule
