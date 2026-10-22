`timescale 1ns / 1ps                            ////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/03 14:36:36
// Design Name:     gs_full_quality
// Module Name:     gs_full_quality
// Description:     gs_full_quality_spec.md
// Simulations:     sim/tb_gs_full_quality.v
//
// Referrences:     None
//
// Dependencies:    gs_quality_context.v, gs_quality_binding.v, gs_time_composition.v
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
// 设计名称:        gs_full_quality
// 模块名称:        gs_full_quality
// 模块说明:        gs_full_quality_spec.md
// 仿真工程:        sim/tb_gs_full_quality.v
//
// 参考资料:        None
//
// 依赖文件:        gs_quality_context.v, gs_quality_binding.v, gs_time_composition.v
//
// 当前版本:        V1.0
// 修订日期:        2026年10月03日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月03日   V1.0        Relay project              创建文件

module gs_full_quality
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 共享本地时钟
	input i_rst,                                // 同步高有效复位
	input i_clear,                              // 全部流水冲刷
	//-----------------用户接口-----------------//
	input i_valid,                              // 接受事务有效
	input [8:0] i_count,                        // 统计总量
	input [8:0] i_delivered,                    // 统计送达量
	input [8:0] i_window,                       // 冻结窗口容量
	input [8:0] i_minimum,                      // 冻结最小样本量
	input [9:0] i_low,                          // 冻结低阈值
	input [9:0] i_high,                         // 冻结恢复阈值
	input [223:0] i_active,                     // 控制身份与修订快照
	input [353:0] i_context,                    // 完整来源证据
	input [15:0] i_tag,                         // 可重复诊断标签
	input i_evidence_present,                   // 证据存在标记
	input [63:0] i_now_ms,                      // 原评估时刻
	input [63:0] i_max_age_ms,                  // 原过期阈值
	output o_valid,                             // E加十八拍结果有效
	output [3:0] o_reason,                      // 最终优先级原因
	output [2:0] o_condition,                   // 完整语义条件
	output o_usable,                            // 是否允许使用数值
	output [15:0] o_tag,                        // 返回原标签
	output [353:0] o_context,                   // 返回原证据
	output [63:0] o_evaluated_ms                // 返回原始评估时刻
);
	//--------------模块实例化信号--------------//
	// 前级计算和归属结果
	wire [15:0] wire_quality_tag;               // 数值结果所属的输入标签
	wire [2:0] wire_quality_code;               // 比较器输出的质量类别
	wire [353:0] wire_quality_context;          // 数值流水同行的来源元数据
	wire [15:0] wire_binding_tag;               // 归属判定返回的诊断标识
	wire [2:0] wire_binding_code;               // 完成身份检查后透传的数值分类
	wire [353:0] wire_binding_context;          // 绑定出口的完整证据快照
	wire [1:0] wire_binding_status;             // 当前身份及配置匹配结果
	//----------------寄存器信号----------------//
	reg [224:0] reg_active_first;               // 入口捕获的当前节点会话及配置
	reg [224:0] reg_active_second;              // 随乘积运算推进的控制身份
	reg [224:0] reg_active_third;               // 比较阶段对应的活动修订
	reg [224:0] reg_active_fourth;              // 质量编码前保存的控制快照
	reg [224:0] reg_active_fifth;               // 供归属核心采样的冻结身份
	reg [129:0] reg_side_first;                 // 原评估时刻和时效参数
	reg [129:0] reg_side_second;                // 数值乘法拍保留的时间基准
	reg [129:0] reg_side_third;                 // 数值比较拍保存的过期设置
	reg [129:0] reg_side_fourth;                // 质量选择期间同行的存在标记
	reg [129:0] reg_side_fifth;                 // 数值输出沿对应的时间记录
	reg [129:0] reg_side_sixth;                 // 归属接受沿保持的源评估数据
	reg [129:0] reg_side_seventh;               // 身份归并期间保存的期限
	reg [129:0] reg_side_eighth;                // 供时间核消费的原始毫秒快照
	reg reg_bad_window_zero;                    // 窗口容量为零
	reg reg_bad_window_range;                   // 容量超过二百五十六
	reg reg_bad_minimum_zero;                   // 最少样本没有配置
	reg reg_bad_minimum_range;                  // 预热量超过窗口
	reg reg_bad_low_range;                      // 低阈值超过允许上界
	reg reg_bad_threshold_order;                // 低阈值不小于恢复阈值
	reg reg_bad_high_range;                     // 恢复阈值超过千分比范围
	reg reg_bad_maximum_zero;                   // 过期时限为空
	reg reg_bad_maximum_range;                  // 时限进入禁止的最高位范围
	reg reg_bad_now_range;                      // 当前时间超出单调域
	reg reg_bad_node_zero;                      // 当前节点编号缺失
	reg reg_bad_session_zero;                   // 活动会话标识为零
	reg reg_bad_epoch_zero;                     // 控制运行代未建立
	reg reg_bad_revision_zero;                  // 当前配置修订无效
	reg reg_reject_pair_alpha;                  // 窗口零值与容量越界
	reg reg_reject_pair_beta;                   // 最少样本及窗口约束
	reg reg_reject_pair_gamma;                  // 阈值低界与次序
	reg reg_reject_pair_delta;                  // 恢复高界及期限零值
	reg reg_reject_pair_epsilon;                // 期限最高位与当前时间
	reg reg_reject_pair_zeta;                   // 节点和会话合法性
	reg reg_reject_pair_eta;                    // 运行代与修订合法性
	reg reg_reject_quarter_alpha;               // 窗口和预热参数拒绝
	reg reg_reject_quarter_beta;                // 质量阈值及期限零拒绝
	reg reg_reject_quarter_gamma;               // 时间域与节点会话拒绝
	reg reg_reject_quarter_delta;               // 配置归属控制拒绝
	reg reg_reject_half_alpha;                  // 统计策略参数非法
	reg reg_reject_half_beta;                   // 时间身份控制非法
	reg reg_reject_root_alpha;                  // 全部原始控制的最高优先拒绝
	reg reg_global_sixth;                       // 归属输入拍的控制拒绝
	reg reg_global_seventh;                     // 绑定中间级的非法标志
	reg reg_global_eighth;                      // 时间接受前的全局错误
	//-----------------标志信号-----------------//
	wire flag_quality_valid;                    // 数值与上下文完成
	wire flag_binding_valid;                    // 同笔归属判定完成
	//-----------------其他信号-----------------//
	// 统一在途撤销
	wire wire_flush;                            // 本地所有附加流水同步清除
	//-----------------输出信号-----------------//
	//用户接口
	wire valid_o;                               // E加十八拍结果有效桥接
	wire [3:0] reason_o;                        // 最终优先级原因桥接
	wire [2:0] condition_o;                     // 完整语义条件桥接
	wire usable_o;                              // 是否允许使用数值桥接
	wire [15:0] tag_o;                          // 返回原标签桥接
	wire [353:0] context_o;                     // 返回原证据桥接
	wire [63:0] evaluated_ms_o;                 // 返回原始评估时刻桥接
	//---------------其他信号连线---------------//
	assign wire_flush = i_rst | i_clear;        // 输入与在途同时撤销
	//---------------输出信号连线---------------//
	//用户接口
	assign o_valid = valid_o;                   // 提交到消费者的有效握手
	assign o_reason = reason_o;                 // 返回优先树胜出的分类编码
	assign o_condition = condition_o;           // 向告警适配器提供判决语义
	assign o_usable = usable_o;                 // 禁止错误证据作为链路数值使用
	assign o_tag = tag_o;                       // 输出与来源数据同行的核对标识
	assign o_context = context_o;               // 保留完整身份和观察记录
	assign o_evaluated_ms = evaluated_ms_o;     // 维持原始判定时间基准
	//-------------主要任务处理区域-------------//
	// 入口捕获的当前节点会话及配置的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_active_first <= 225'd0;         // 清除本级在途标记：入口捕获的当前节点会话及配置
		end else begin
			reg_active_first <= {i_valid, i_active}; // 捕获输入判定：入口捕获的当前节点会话及配置
		end
	end

	// 随乘积运算推进的控制身份的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_active_second <= 225'd0;        // 清除本级在途标记：随乘积运算推进的控制身份
		end else begin
			reg_active_second <= reg_active_first; // 捕获输入判定：随乘积运算推进的控制身份
		end
	end

	// 比较阶段对应的活动修订的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_active_third <= 225'd0;         // 清除本级在途标记：比较阶段对应的活动修订
		end else begin
			reg_active_third <= reg_active_second; // 捕获输入判定：比较阶段对应的活动修订
		end
	end

	// 质量编码前保存的控制快照的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_active_fourth <= 225'd0;        // 清除本级在途标记：质量编码前保存的控制快照
		end else begin
			reg_active_fourth <= reg_active_third; // 捕获输入判定：质量编码前保存的控制快照
		end
	end

	// 供归属核心采样的冻结身份的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_active_fifth <= 225'd0;         // 清除本级在途标记：供归属核心采样的冻结身份
		end else begin
			reg_active_fifth <= reg_active_fourth; // 捕获输入判定：供归属核心采样的冻结身份
		end
	end

	// 原评估时刻和时效参数的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_first <= 130'd0;           // 清除本级在途标记：原评估时刻和时效参数
		end else begin
			reg_side_first <= {i_valid, i_evidence_present, i_now_ms, i_max_age_ms}; // 捕获输入判定：原评估时刻和时效参数
		end
	end

	// 数值乘法拍保留的时间基准的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_second <= 130'd0;          // 清除本级在途标记：数值乘法拍保留的时间基准
		end else begin
			reg_side_second <= reg_side_first;  // 捕获输入判定：数值乘法拍保留的时间基准
		end
	end

	// 数值比较拍保存的过期设置的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_third <= 130'd0;           // 清除本级在途标记：数值比较拍保存的过期设置
		end else begin
			reg_side_third <= reg_side_second;  // 捕获输入判定：数值比较拍保存的过期设置
		end
	end

	// 质量选择期间同行的存在标记的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_fourth <= 130'd0;          // 清除本级在途标记：质量选择期间同行的存在标记
		end else begin
			reg_side_fourth <= reg_side_third;  // 捕获输入判定：质量选择期间同行的存在标记
		end
	end

	// 数值输出沿对应的时间记录的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_fifth <= 130'd0;           // 清除本级在途标记：数值输出沿对应的时间记录
		end else begin
			reg_side_fifth <= reg_side_fourth;  // 捕获输入判定：数值输出沿对应的时间记录
		end
	end

	// 归属接受沿保持的源评估数据的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_sixth <= 130'd0;           // 清除本级在途标记：归属接受沿保持的源评估数据
		end else begin
			reg_side_sixth <= reg_side_fifth;   // 捕获输入判定：归属接受沿保持的源评估数据
		end
	end

	// 身份归并期间保存的期限的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_seventh <= 130'd0;         // 清除本级在途标记：身份归并期间保存的期限
		end else begin
			reg_side_seventh <= reg_side_sixth; // 捕获输入判定：身份归并期间保存的期限
		end
	end

	// 供时间核消费的原始毫秒快照的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_side_eighth <= 130'd0;          // 清除本级在途标记：供时间核消费的原始毫秒快照
		end else begin
			reg_side_eighth <= reg_side_seventh; // 捕获输入判定：供时间核消费的原始毫秒快照
		end
	end

	// 窗口容量为零的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_window_zero <= 1'd0;        // 清除本级在途标记：窗口容量为零
		end else begin
			reg_bad_window_zero <= (i_window == 9'd0); // 捕获输入判定：窗口容量为零
		end
	end

	// 容量超过二百五十六的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_window_range <= 1'd0;       // 清除本级在途标记：容量超过二百五十六
		end else begin
			reg_bad_window_range <= (i_window > 9'd256); // 捕获输入判定：容量超过二百五十六
		end
	end

	// 最少样本没有配置的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_minimum_zero <= 1'd0;       // 清除本级在途标记：最少样本没有配置
		end else begin
			reg_bad_minimum_zero <= (i_minimum == 9'd0); // 捕获输入判定：最少样本没有配置
		end
	end

	// 预热量超过窗口的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_minimum_range <= 1'd0;      // 清除本级在途标记：预热量超过窗口
		end else begin
			reg_bad_minimum_range <= (i_minimum > i_window); // 捕获输入判定：预热量超过窗口
		end
	end

	// 低阈值超过允许上界的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_low_range <= 1'd0;          // 清除本级在途标记：低阈值超过允许上界
		end else begin
			reg_bad_low_range <= (i_low > 10'd999); // 捕获输入判定：低阈值超过允许上界
		end
	end

	// 低阈值不小于恢复阈值的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_threshold_order <= 1'd0;    // 清除本级在途标记：低阈值不小于恢复阈值
		end else begin
			reg_bad_threshold_order <= (i_low >= i_high); // 捕获输入判定：低阈值不小于恢复阈值
		end
	end

	// 恢复阈值超过千分比范围的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_high_range <= 1'd0;         // 清除本级在途标记：恢复阈值超过千分比范围
		end else begin
			reg_bad_high_range <= (i_high > 10'd1000); // 捕获输入判定：恢复阈值超过千分比范围
		end
	end

	// 过期时限为空的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_maximum_zero <= 1'd0;       // 清除本级在途标记：过期时限为空
		end else begin
			reg_bad_maximum_zero <= (i_max_age_ms == 64'd0); // 捕获输入判定：过期时限为空
		end
	end

	// 时限进入禁止的最高位范围的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_maximum_range <= 1'd0;      // 清除本级在途标记：时限进入禁止的最高位范围
		end else begin
			reg_bad_maximum_range <= (i_max_age_ms[63]); // 捕获输入判定：时限进入禁止的最高位范围
		end
	end

	// 当前时间超出单调域的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_now_range <= 1'd0;          // 清除本级在途标记：当前时间超出单调域
		end else begin
			reg_bad_now_range <= (i_now_ms[63]); // 捕获输入判定：当前时间超出单调域
		end
	end

	// 当前节点编号缺失的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_node_zero <= 1'd0;          // 清除本级在途标记：当前节点编号缺失
		end else begin
			reg_bad_node_zero <= (i_active[223:192] == 32'd0); // 捕获输入判定：当前节点编号缺失
		end
	end

	// 活动会话标识为零的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_session_zero <= 1'd0;       // 清除本级在途标记：活动会话标识为零
		end else begin
			reg_bad_session_zero <= (i_active[191:128] == 64'd0); // 捕获输入判定：活动会话标识为零
		end
	end

	// 控制运行代未建立的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_epoch_zero <= 1'd0;         // 清除本级在途标记：控制运行代未建立
		end else begin
			reg_bad_epoch_zero <= (i_active[127:64] == 64'd0); // 捕获输入判定：控制运行代未建立
		end
	end

	// 当前配置修订无效的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_bad_revision_zero <= 1'd0;      // 清除本级在途标记：当前配置修订无效
		end else begin
			reg_bad_revision_zero <= (i_active[63:0] == 64'd0); // 捕获输入判定：当前配置修订无效
		end
	end

	// 窗口零值与容量越界的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_alpha <= 1'd0;      // 清除本级在途标记：窗口零值与容量越界
		end else begin
			reg_reject_pair_alpha <= reg_bad_window_zero | reg_bad_window_range; // 捕获输入判定：窗口零值与容量越界
		end
	end

	// 最少样本及窗口约束的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_beta <= 1'd0;       // 清除本级在途标记：最少样本及窗口约束
		end else begin
			reg_reject_pair_beta <= reg_bad_minimum_zero | reg_bad_minimum_range; // 捕获输入判定：最少样本及窗口约束
		end
	end

	// 阈值低界与次序的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_gamma <= 1'd0;      // 清除本级在途标记：阈值低界与次序
		end else begin
			reg_reject_pair_gamma <= reg_bad_low_range | reg_bad_threshold_order; // 捕获输入判定：阈值低界与次序
		end
	end

	// 恢复高界及期限零值的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_delta <= 1'd0;      // 清除本级在途标记：恢复高界及期限零值
		end else begin
			reg_reject_pair_delta <= reg_bad_high_range | reg_bad_maximum_zero; // 捕获输入判定：恢复高界及期限零值
		end
	end

	// 期限最高位与当前时间的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_epsilon <= 1'd0;    // 清除本级在途标记：期限最高位与当前时间
		end else begin
			reg_reject_pair_epsilon <= reg_bad_maximum_range | reg_bad_now_range; // 捕获输入判定：期限最高位与当前时间
		end
	end

	// 节点和会话合法性的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_zeta <= 1'd0;       // 清除本级在途标记：节点和会话合法性
		end else begin
			reg_reject_pair_zeta <= reg_bad_node_zero | reg_bad_session_zero; // 捕获输入判定：节点和会话合法性
		end
	end

	// 运行代与修订合法性的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_pair_eta <= 1'd0;        // 清除本级在途标记：运行代与修订合法性
		end else begin
			reg_reject_pair_eta <= reg_bad_epoch_zero | reg_bad_revision_zero; // 捕获输入判定：运行代与修订合法性
		end
	end

	// 窗口和预热参数拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_quarter_alpha <= 1'd0;   // 清除本级在途标记：窗口和预热参数拒绝
		end else begin
			reg_reject_quarter_alpha <= reg_reject_pair_alpha | reg_reject_pair_beta; // 捕获输入判定：窗口和预热参数拒绝
		end
	end

	// 质量阈值及期限零拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_quarter_beta <= 1'd0;    // 清除本级在途标记：质量阈值及期限零拒绝
		end else begin
			reg_reject_quarter_beta <= reg_reject_pair_gamma | reg_reject_pair_delta; // 捕获输入判定：质量阈值及期限零拒绝
		end
	end

	// 时间域与节点会话拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_quarter_gamma <= 1'd0;   // 清除本级在途标记：时间域与节点会话拒绝
		end else begin
			reg_reject_quarter_gamma <= reg_reject_pair_epsilon | reg_reject_pair_zeta; // 捕获输入判定：时间域与节点会话拒绝
		end
	end

	// 配置归属控制拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_quarter_delta <= 1'd0;   // 清除本级在途标记：配置归属控制拒绝
		end else begin
			reg_reject_quarter_delta <= reg_reject_pair_eta; // 捕获输入判定：配置归属控制拒绝
		end
	end

	// 统计策略参数非法的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_half_alpha <= 1'd0;      // 清除本级在途标记：统计策略参数非法
		end else begin
			reg_reject_half_alpha <= reg_reject_quarter_alpha | reg_reject_quarter_beta; // 捕获输入判定：统计策略参数非法
		end
	end

	// 时间身份控制非法的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_half_beta <= 1'd0;       // 清除本级在途标记：时间身份控制非法
		end else begin
			reg_reject_half_beta <= reg_reject_quarter_gamma | reg_reject_quarter_delta; // 捕获输入判定：时间身份控制非法
		end
	end

	// 全部原始控制的最高优先拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_reject_root_alpha <= 1'd0;      // 清除本级在途标记：全部原始控制的最高优先拒绝
		end else begin
			reg_reject_root_alpha <= reg_reject_half_alpha | reg_reject_half_beta; // 捕获输入判定：全部原始控制的最高优先拒绝
		end
	end

	// 归属输入拍的控制拒绝的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_global_sixth <= 1'd0;           // 清除本级在途标记：归属输入拍的控制拒绝
		end else begin
			reg_global_sixth <= reg_reject_root_alpha; // 捕获输入判定：归属输入拍的控制拒绝
		end
	end

	// 绑定中间级的非法标志的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_global_seventh <= 1'd0;         // 清除本级在途标记：绑定中间级的非法标志
		end else begin
			reg_global_seventh <= reg_global_sixth; // 捕获输入判定：绑定中间级的非法标志
		end
	end

	// 时间接受前的全局错误的采样和同步撤销。
	always@(posedge i_clk)begin
		if(wire_flush)begin
			reg_global_eighth <= 1'd0;          // 清除本级在途标记：时间接受前的全局错误
		end else begin
			reg_global_eighth <= reg_global_seventh; // 捕获输入判定：时间接受前的全局错误
		end
	end

	//--------------模块实例化区域--------------//
	// 数值和证据在E加四拍完成
	gs_quality_context Quality_Inst(
		.i_clk(i_clk),                          // 数值：公共采样时钟
		.i_rst(i_rst),                          // 数值：同步复位入口
		.i_clear(i_clear),                      // 数值：撤销全部在途数据
		.i_valid(i_valid),                      // 数值：该级接受有效事务
		.i_tag(i_tag),                          // 数值：诊断事务标签
		.i_count(i_count),                      // 数值：窗口内统计数量
		.i_delivered(i_delivered),              // 数值：实际送达事件数
		.i_window(i_window),                    // 数值：统计窗口配置
		.i_minimum(i_minimum),                  // 数值：最低预热数量
		.i_low(i_low),                          // 数值：低质量阈值
		.i_high(i_high),                        // 数值：恢复质量阈值
		.i_context(i_context),                  // 数值：完整来源上下文
		.o_valid(flag_quality_valid),           // 数值：本级计算完成指示
		.o_tag(wire_quality_tag),               // 数值：对应原请求的标签
		.o_code(wire_quality_code),             // 数值：数值分类透传
		.o_context(wire_quality_context)        // 数值：同笔证据记录输出
	);

	// 使用E沿冻结身份完成归属检查
	gs_quality_binding Binding_Inst(
		.i_clk(i_clk),                          // 归属：公共采样时钟
		.i_rst(i_rst),                          // 归属：同步复位入口
		.i_clear(i_clear),                      // 归属：撤销全部在途数据
		.i_valid(flag_quality_valid),           // 归属：该级接受有效事务
		.i_active(reg_active_fifth[223:0]),     // 归属：入口冻结的当前身份
		.i_context(wire_quality_context),       // 归属：完整来源上下文
		.i_tag(wire_quality_tag),               // 归属：诊断事务标签
		.i_code(wire_quality_code),             // 归属：已计算的数值质量
		.o_valid(flag_binding_valid),           // 归属：本级计算完成指示
		.o_binding(wire_binding_status),        // 归属：身份优先配置其次的归属编码
		.o_context(wire_binding_context),       // 归属：同笔证据记录输出
		.o_tag(wire_binding_tag),               // 归属：对应原请求的标签
		.o_code(wire_binding_code)              // 归属：数值分类透传
	);

	// E加八拍接收并在E加十八拍交付
	gs_time_composition TimeComposition_Inst(
		.i_clk(i_clk),                          // 时间合成：公共采样时钟
		.i_rst(i_rst),                          // 时间合成：同步复位入口
		.i_clear(i_clear),                      // 时间合成：撤销全部在途数据
		.i_valid(flag_binding_valid),           // 时间合成：该级接受有效事务
		.i_quality(wire_binding_code),          // 时间合成：数值分类进入时间合成
		.i_binding(wire_binding_status),        // 时间合成：绑定检查结果
		.i_global_invalid(reg_global_eighth),   // 时间合成：原始控制参数非法
		.i_evidence_present(reg_side_eighth[128]), // 时间合成：统计证据存在性
		.i_tag(wire_binding_tag),               // 时间合成：诊断事务标签
		.i_context(wire_binding_context),       // 时间合成：完整来源上下文
		.i_now_ms(reg_side_eighth[127:64]),     // 时间合成：原事务的时间评估点
		.i_max_age_ms(reg_side_eighth[63:0]),   // 时间合成：冻结的来源过期时限
		.o_valid(valid_o),                      // 时间合成：本级计算完成指示
		.o_reason(reason_o),                    // 时间合成：最终优先级判定原因
		.o_condition(condition_o),              // 时间合成：下游告警语义条件
		.o_usable(usable_o),                    // 时间合成：有效质量使用许可
		.o_tag(tag_o),                          // 时间合成：对应原请求的标签
		.o_context(context_o),                  // 时间合成：同笔证据记录输出
		.o_evaluated_ms(evaluated_ms_o)         // 时间合成：随结果返回历史评估时刻
	);

endmodule
