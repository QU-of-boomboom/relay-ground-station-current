`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/04 14:36:36
// Design Name:     gs_quality_publication
// Module Name:     gs_quality_publication
// Description:     gs_quality_publication_spec.md
// Simulations:     sim/tb_gs_quality_publication.v
//
// Referrences:     None
//
// Dependencies:    gs_full_quality.v, gs_parallel_publication_guard.v
//
// Version:         V1.0
// Revision Date:   2026/10/04 14:36:36
// History:
// Time             Version     Revised by        Contents
// 2026/10/04       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月04日
// 设计名称:        gs_quality_publication
// 模块名称:        gs_quality_publication
// 模块说明:        gs_quality_publication_spec.md
// 仿真工程:        sim/tb_gs_quality_publication.v
//
// 参考资料:        None
//
// 依赖文件:        gs_full_quality.v, gs_parallel_publication_guard.v
//
// 当前版本:        V1.0
// 修订日期:        2026年10月04日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月04日   V1.0        Relay project              创建文件

module gs_quality_publication #(
	parameter [31:0] C_CLOCKS_PER_MS = 32'd32  // 整链毫秒周期至少二十二拍
)(
	//-----------------全局信号-----------------//
	input i_clk,                                // 公共同域时钟
	input i_rst,                                // 同步高有效复位
	//-----------------用户接口-----------------//
	input i_change,                             // 本沿代号变化及全链冲刷
	input i_blocked,                            // 来源缓存不可用
	input i_suppress,                           // 上游提交清除窗口
	input i_tick,                               // 同域毫秒首沿请求
	input [8:0] i_count,                        // 当前统计总量
	input [8:0] i_delivered,                    // 当前送达量
	input [8:0] i_window,                       // 窗口容量
	input [8:0] i_minimum,                      // 最小预热量
	input [9:0] i_low,                          // 低质量阈值
	input [9:0] i_high,                         // 恢复阈值
	input [223:0] i_active,                     // 当前活动身份与修订
	input [353:0] i_context,                    // 原始来源上下文
	input [15:0] i_tag,                         // 诊断标签不代替代号
	input i_evidence_present,                   // 统计证据存在
	input [63:0] i_now_ms,                      // 当前本地评估时间
	input [63:0] i_max_age_ms,                  // 来源过期期限
	output [7:0] o_generation,                  // 本沿最新缓存代号
	output o_request,                           // 下一沿质量输入使能
	output o_schedule_fault,                    // 调度缺失诊断
	output o_publication,                       // 新结果发布事件
	output o_current_valid,                     // 当前结果可消费
`ifdef GS_SHARED_QUALITY
    output o_compute_request, // S沿质量重评请求，原样送往共享队列
    output o_compute_cancel, // 本来源复位或缓存变化，撤销旧计算
    output [778:0] o_compute_payload, // 与请求同行的完整原始质量输入
    output [7:0] o_compute_generation, // 与输入同行的本沿新代号
    input i_compute_valid, // 仅本来源的共享返回资格
    input [7:0] i_compute_generation, // 返回结果保留的原请求代号
    input [441:0] i_compute_payload, // 原质量结果，不刷新评估时刻
`endif
	output [441:0] o_current_payload            // 无效时为零的完整结果
);
	//--------------模块实例化信号--------------//
	wire [441:0] wire_payload;                  // 子模块直接驱动互不重叠的完整候选字段
	// 质量链候选结果
	//----------------寄存器信号----------------//
`ifndef GS_SHARED_QUALITY
	reg [778:0] reg_snapshot;                   // 每沿完整冻结原始质量输入
	reg [7:0] reg_snapshot_generation;          // 与快照对应的本沿新代号
	reg [151:0] reg_generation_pipe;            // 十九个8位代号位置
`endif
	wire [7:0] wire_candidate_generation;       // 候选实际所属代号，不读取当前代替
	//-----------------标志信号-----------------//
	wire flag_quality_valid;                    // 质量输出有效
	//-----------------其他信号-----------------//
	// 对齐与显式模运算
	wire [8:0] wire_increment;                  // 九位显式计算代号增量
	wire wire_flush;                            // 同步复位或增代冲刷
	//-----------------输出信号-----------------//
	//用户接口
	wire [7:0] generation_o;                    // 发布控制当前代号
	wire request_o;                             // 发布控制的注册请求
	wire fault_o;                               // 发布控制的调度健康
	wire publication_o;                         // 新提交事件
	wire current_valid_o;                       // 持有结果有效性
	wire [441:0] current_payload_o;             // 完整持有结果
	//---------------其他信号连线---------------//
	assign wire_increment = {1'b0,generation_o} + {8'd0,i_change}; // 与发布控制同沿增代一致
	assign wire_flush = i_rst | i_change;       // 同步清除整个代号旁路
	//---------------输出信号连线---------------//
	//用户接口
	assign o_generation = generation_o;         // 对外报告内部代号
	assign o_request = request_o;               // 对外观察重评请求
	assign o_schedule_fault = fault_o;          // 调度监督出口
	assign o_publication = publication_o;       // 新发布事件出口
	assign o_current_valid = current_valid_o;   // 可见结果有效性
	assign o_current_payload = current_payload_o; // 无效时由发布控制屏蔽
`ifdef GS_SHARED_QUALITY
    assign o_compute_request=({i_rst,i_tick,i_blocked,i_suppress}==4'b0100);
    assign o_compute_cancel=i_rst | i_change;
    assign o_compute_payload={i_count,i_delivered,i_window,i_minimum,i_low,i_high,i_active,i_context,i_tag,i_evidence_present,i_now_ms,i_max_age_ms};
    assign o_compute_generation=wire_increment[7:0];
    assign flag_quality_valid=i_compute_valid;
    assign wire_candidate_generation=i_compute_generation;
    assign wire_payload=i_compute_payload;
`else
	assign wire_candidate_generation=reg_generation_pipe[151:144];
	//-------------主要任务处理区域-------------//
	// 全量快照在S沿冻结，S加一沿仅在注册request时消费。
	always @(posedge i_clk) begin
		reg_snapshot <= {i_count,i_delivered,i_window,i_minimum,i_low,i_high,i_active,i_context,i_tag,i_evidence_present,i_now_ms,i_max_age_ms}; // 原始字段同行冻结
	end

	// 同步保存快照所属的本沿更新后代号。
	always @(posedge i_clk) begin
		if(i_rst) begin
			reg_snapshot_generation <= 8'd0;    // 有效复位后代号归零
		end
		else begin
			reg_snapshot_generation <= wire_increment[7:0]; // 保留显式八位模结果
		end
	end

	// 代号入口与质量接受沿一致，出口与E加十八结果对齐。
	always @(posedge i_clk) begin
		if(wire_flush) begin
			reg_generation_pipe <= 152'd0;      // 撤销所有在途代号
		end
		else begin
			reg_generation_pipe <= {reg_generation_pipe[143:0],(request_o ? reg_snapshot_generation : 8'd0)}; // 空拍也推进并填零
		end
	end
	//---------------模块实例化区域---------------//
	// 原质量链消费同一S沿快照，并共享同步reset/change。
`ifdef GS_COMPACT_STORAGE
	gs_full_quality_compact Full_Inst(            // 元数据BRAM旁路保持原质量周期
`else
	gs_full_quality Full_Inst(                    // 冻结快照进入质量运算核心
`endif
		.i_clk(i_clk),                            // 公共时钟
		.i_rst(i_rst),                            // 同步复位
		.i_clear(i_change),                       // 本沿缓存增代撤销
		.i_valid(request_o),                      // 只消费已登记请求
		.i_count(reg_snapshot[778:770]),          // 冻结总量
		.i_delivered(reg_snapshot[769:761]),      // 冻结送达量
		.i_window(reg_snapshot[760:752]),         // 冻结窗口
		.i_minimum(reg_snapshot[751:743]),        // 冻结预热量
		.i_low(reg_snapshot[742:733]),            // 冻结低阈值
		.i_high(reg_snapshot[732:723]),           // 冻结恢复阈值
		.i_active(reg_snapshot[722:499]),         // 冻结活动身份
		.i_context(reg_snapshot[498:145]),        // 冻结来源证据
		.i_tag(reg_snapshot[144:129]),            // 冻结标签
		.i_evidence_present(reg_snapshot[128]),   // 冻结存在性
		.i_now_ms(reg_snapshot[127:64]),          // 冻结原评估时间
		.i_max_age_ms(reg_snapshot[63:0]),        // 冻结过期配置
		.o_valid(flag_quality_valid),             // 候选产生沿后有效
		.o_reason(wire_payload[441:438]),         // 原因编码
		.o_condition(wire_payload[437:435]),      // 条件编码
		.o_usable(wire_payload[434]),             // 数值使用许可
		.o_tag(wire_payload[433:418]),            // 原诊断标签
		.o_context(wire_payload[417:64]),         // 原来源证据
		.o_evaluated_ms(wire_payload[63:0])       // 原时间
	);
`endif

	// 发布控制在下一沿采到质量候选，再下一沿提交。
	gs_parallel_publication_guard #(              // 对齐候选进入发布控制核心
		.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS)         // 整链合同要求至少二十二

	// 当前控制与旧候选在发布模块汇合。
	) Guard_Inst(
		.i_clk(i_clk),                            // 发布资格登记时钟
		.i_rst(i_rst),                            // 撤销持有与在途资格
		.i_change(i_change),                      // 当前增代事件
		.i_blocked(i_blocked),                    // 当前来源可用性
		.i_suppress(i_suppress),                  // 当前清除窗口
		.i_tick(i_tick),                          // 当前调度首沿
		.i_now_ms(i_now_ms),                      // 当前时间不可使用快照替代
		.i_candidate_valid(flag_quality_valid),   // 前沿完成的质量候选
		.i_candidate_generation(wire_candidate_generation), // 同行完整代号
		.i_candidate_payload(wire_payload),       // 不刷新时间的原候选
		.o_generation(generation_o),              // 同沿新代号
		.o_request(request_o),                    // 下沿输入质量链
		.o_schedule_fault(fault_o),               // 故障监督
		.o_publication(publication_o),            // 新发布事件
		.o_current_valid(current_valid_o),        // 当前结果有效性
		.o_current_payload(current_payload_o)     // 无效时清零
	);

endmodule
