`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/02 19:08:21
// Design Name:     gs_pdr_alarm
// Module Name:     gs_pdr_alarm
// Description:     gs_pdr_alarm_spec.md
// Simulations:     sim/tb_gs_pdr_alarm.v
//
// Referrences:     None
//
// Dependencies:    None
//
// Version:         V1.0
// Revision Date:   2026/10/02 19:08:21
// History:
// Time             Version     Revised by        Contents
// 2026/10/02       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月02日
// 设计名称:        gs_pdr_alarm
// 模块名称:        gs_pdr_alarm
// 模块说明:        gs_pdr_alarm_spec.md
// 仿真工程:        sim/tb_gs_pdr_alarm.v
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

module gs_pdr_alarm
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 本地采样时钟。
	input i_rstn,                               // 异步低有效复位，释放由上游同步。
	input i_clear,                              // 身份或配置变化时清除历史。

	//-----------------用户接口-----------------//
	input i_tick_ms,                            // 单周期毫秒采样使能。
	input [1:0]i_condition,                     // 不可用、低质量、中间区间、良好。
	input [15:0]i_bad_hold,                     // 连续低质量触发时长。
	input [15:0]i_good_hold,                    // 连续良好恢复时长。
	output [2:0]o_state,                        // 当前判别阶段。
	output o_valid,                             // 告警是否基于有效证据。
	output o_alarm                              // 仅有效时解释为持续告警。
);

	//---------------状态参数区域---------------//
	localparam [2:0]ST_UNAVAILABLE = 3'd0;      // 证据不可用，等待下一次有效采样
	localparam [2:0]ST_CLEAR = 3'd1;            // 证据有效且未达到告警条件
	localparam [2:0]ST_PENDING = 3'd2;          // 连续低质量累计触发时长
	localparam [2:0]ST_ALARM = 3'd3;            // 告警保持，等待连续恢复证据
	localparam [2:0]ST_RECOVERING = 3'd4;       // 告警仍有效，累计恢复时长

	//-----------------计数信号-----------------//
	reg [15:0]cnt_elapsed = 16'd0;              // 当前连续区段经过的后续毫秒数。

	//----------------状态机信号----------------//
	reg [2:0]state_current = 3'd0;              // 保存当前阶段。
	reg [2:0]state_next = 3'd0;                 // 组合计算的下一阶段。

	//----------------寄存器信号----------------//
	// 连续区段的预计算比较门限
	reg [15:0]reg_bad_limit = 16'd0;            // 触发时长减一，供下一时钟沿比较
	reg [15:0]reg_good_limit = 16'd0;           // 恢复时长减一，供下一时钟沿比较

	//-----------------其他信号-----------------//
	// 计时递增中间结果
	wire [16:0]elapsed_increment;               // 保留进位，写回时显式选择低位。
	wire [16:0]bad_limit_difference;            // 扩展触发配置，保留减法借位
	wire [16:0]good_limit_difference;           // 扩展恢复配置，明确无效零值的截取

	//---------------其他信号连线---------------//
	//其他信号连线
	assign elapsed_increment = {1'b0, cnt_elapsed} + 17'd1; // 门限条件保护下低位不会回绕。
	assign bad_limit_difference = {1'b0, i_bad_hold} - 17'd1; // 零配置回绕值由有效性判断隔离
	assign good_limit_difference = {1'b0, i_good_hold} - 17'd1; // 有效正配置得到精确恢复边界

	//---------------输出信号连线---------------//
	//用户接口
	assign o_state = state_current;             // 状态对外观察接口。
	assign o_valid = (state_current != ST_UNAVAILABLE); // 无数据不提供有效告警。
	assign o_alarm = (state_current == ST_ALARM) || (state_current == ST_RECOVERING); // 恢复计时期间保持告警。

	//----------------状态机区域----------------//
	// 状态寄存过程：复位立即撤销有效证据
	always@(posedge i_clk or negedge i_rstn)begin
		if(i_rstn == 1'b0)begin
			state_current <= ST_UNAVAILABLE;    // 复位撤销此前全部判别证据
		end else begin
			state_current <= state_next;        // 采样沿提交已经算好的后继阶段
		end
	end

	// 组合转移过程：按当前质量及持续时长选择后继
	always@(*)begin
		state_next = state_current;             // 默认保持以覆盖所有组合分支
		if(i_clear == 1'b1)begin
			state_next = ST_UNAVAILABLE;        // 会话清除请求优先终止历史
		end else if(i_tick_ms == 1'b1)begin
			if(i_bad_hold == 16'd0 || i_good_hold == 16'd0 || i_condition == 2'd0)begin
				state_next = ST_UNAVAILABLE;    // 无效质量或零配置使结果失去效力
			end else begin
				case(state_current)

					// 证据不可用，等待下一次有效采样
					ST_UNAVAILABLE:begin
						if(i_condition == 2'd1)begin
							state_next = ST_PENDING; // 初次收到低质量证据启动等待
						end else begin
							state_next = ST_CLEAR; // 初次可用证据未触发告警
						end
					end

					// 证据有效且未达到告警条件
					ST_CLEAR:begin
						if(i_condition == 2'd1)begin
							state_next = ST_PENDING; // 正常期间转弱后开始连续观察
						end else begin
							state_next = ST_CLEAR; // 正常期间保持未告警状态
						end
					end

					// 连续低质量累计触发时长
					ST_PENDING:begin
						if(i_condition != 2'd1)begin
							state_next = ST_CLEAR; // 连续低质量被打断，取消触发等待
						end else if(cnt_elapsed >= reg_bad_limit)begin
							state_next = ST_ALARM; // 低质量持续时间达到门限，置位告警
						end else begin
							state_next = ST_PENDING; // 触发时长尚不足，继续等待
						end
					end

					// 告警保持，等待连续恢复证据
					ST_ALARM:begin
						if(i_condition == 2'd3)begin
							state_next = ST_RECOVERING; // 告警期间收到良好证据，开始恢复观察
						end else begin
							state_next = ST_ALARM; // 中间或低质量证据继续维持告警
						end
					end

					// 告警仍有效，累计恢复时长
					ST_RECOVERING:begin
						if(i_condition != 2'd3)begin
							state_next = ST_ALARM; // 恢复被打断，返回告警保持
						end else if(cnt_elapsed >= reg_good_limit)begin
							state_next = ST_CLEAR; // 连续良好证据已达恢复门限，解除告警
						end else begin
							state_next = ST_RECOVERING; // 恢复等待尚未结束，继续观察
						end
					end

					// 非法状态退回证据不可用
					default:begin
						state_next = ST_UNAVAILABLE; // 未知状态编码回退到不可判断
					end
				endcase
			end
		end else begin
			state_next = state_current;         // 本拍没有毫秒事件，阶段不推进
		end
	end

	//-------------状态任务处理区域-------------//
	// 计时任务过程：跨阶段清零且只随毫秒事件递增
	always@(posedge i_clk or negedge i_rstn)begin
		if(i_rstn == 1'b0)begin
			cnt_elapsed <= 16'd0;               // 异步复位抹去累计毫秒数
		end else if(i_clear == 1'b1)begin
			cnt_elapsed <= 16'd0;               // 会话清除不依赖毫秒事件
		end else if(i_tick_ms == 1'b1)begin
			if(i_bad_hold == 16'd0 || i_good_hold == 16'd0)begin
				cnt_elapsed <= 16'd0;           // 非法配置终止当前连续区段
			end else if(state_current == ST_PENDING && i_condition == 2'd1 && cnt_elapsed < reg_bad_limit)begin
				cnt_elapsed <= elapsed_increment[15:0]; // 低质量仍连续且未到触发边界
			end else if(state_current == ST_RECOVERING && i_condition == 2'd3 && cnt_elapsed < reg_good_limit)begin
				cnt_elapsed <= elapsed_increment[15:0]; // 良好证据仍连续且未到恢复边界
			end else begin
				cnt_elapsed <= 16'd0;           // 边界到达或质量打断均结束计时
			end
		end
	end

	//-------------主要任务处理区域-------------//
	// 提前计算触发边界，首个低质量tick只进入等待状态
	always@(posedge i_clk or negedge i_rstn)begin
		if(i_rstn == 1'b0)begin
			reg_bad_limit <= 16'd0;             // 复位期间门限寄存器无待用历史
		end else begin
			reg_bad_limit <= bad_limit_difference[15:0]; // clear沿同样采样新触发配置
		end
	end

	// 提前计算恢复边界，首次良好证据不立即解除告警
	always@(posedge i_clk or negedge i_rstn)begin
		if(i_rstn == 1'b0)begin
			reg_good_limit <= 16'd0;            // 复位后先建立新的恢复门限
		end else begin
			reg_good_limit <= good_limit_difference[15:0]; // 连续tick使用前拍已稳定的恢复配置
		end
	end

endmodule
