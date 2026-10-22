`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/03 14:36:36
// Design Name:     gs_parallel_publication_guard
// Module Name:     gs_parallel_publication_guard
// Description:     gs_parallel_publication_guard_spec.md
// Simulations:     sim/tb_gs_parallel_publication_guard.v
//
// Referrences:     None
//
// Dependencies:    None
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
// 设计名称:        gs_parallel_publication_guard
// 模块名称:        gs_parallel_publication_guard
// 模块说明:        gs_parallel_publication_guard_spec.md
// 仿真工程:        sim/tb_gs_parallel_publication_guard.v
//
// 参考资料:        None
//
// 依赖文件:        None
//
// 当前版本:        V1.0
// 修订日期:        2026年10月03日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月03日   V1.0        Relay project              创建文件

module gs_parallel_publication_guard #(
	parameter [31:0] C_CLOCKS_PER_MS = 32'd32   // 每毫秒时钟数，至少二十一
)(
	//-----------------全局信号-----------------//
	input i_clk,                                // 公共PL时钟
	input i_rst,                                // 同步高有效复位
	//-----------------用户接口-----------------//
	input i_change,                             // 本沿缓存增代，含单次commit事件
	input i_blocked,                            // 来源缓存不可用
	input i_suppress,                           // commit毫秒等上游清除窗口
	input i_tick,                               // 同域毫秒首沿请求
	input [63:0] i_now_ms,                      // 当前本地时间
	input i_candidate_valid,                    // 固定寿命候选到达
	input [7:0] i_candidate_generation,         // 完整内部代号
	input [441:0] i_candidate_payload,          // 原结果，低64位是evaluated_ms
	output [7:0] o_generation,                  // 本沿变化后的当前代号
	output o_request,                           // 注册后的重评请求，下一沿消费
	output o_schedule_fault,                    // 调度tick缺失
	output o_publication,                       // 新候选发布脉冲
	output o_current_valid,                     // 持有结果当前有效
	output [441:0] o_current_payload            // 无效时清零
);
	//-----------------本地参数-----------------//
	localparam [31:0] LP_TICK_RELOAD = C_CLOCKS_PER_MS - {31'd0,1'b1}; // tick后的固定倒计数装载值
	localparam [31:0] LP_SHADOW_RELOAD = C_CLOCKS_PER_MS - {30'd0,2'd2}; // tick后预备的下一次递减值
	//----------------寄存器信号----------------//
	reg [7:0] reg_generation;                   // 八位缓存代号
	reg [31:0] reg_remaining;                   // 下一次到期前剩余拍数，零时保持
	reg [31:0] reg_shadow;                      // 未到期时比主计数少一，到期后可回绕
	reg [2:0] reg_controls;                     // 三个资格位分别登记，同行使用
	reg [2:0] reg_candidate_checks;             // 候选存在、版本和时间资格
	reg [1:0] reg_live_checks;                  // 本沿增代标志与结果存活依据
	reg [63:0] reg_sampled_now;                 // 前沿当前时间，与候选和旧有效结果同域
	reg [441:0] reg_sampled_payload;            // 无条件冻结输入，接纳位决定能否使用
	reg [441:0] reg_raw;                        // 最近接纳的内部载荷，无效时允许保留
	//-----------------标志信号-----------------//
	reg flag_due;                               // 预译码的本沿到期状态
	reg flag_selected;                          // 本沿是否装入前沿接纳的候选
	wire flag_pending;                          // 七项前沿接纳资格全部成立
	//-----------------其他信号-----------------//
	// 寄存边界之间的短组合路径
	wire [32:0] wire_shadow_less;               // 辅助计数显式扩展减法
	wire [8:0] wire_increment;                  // 代号进位供模截取
	wire [7:0] wire_generation_next;            // 同沿变更后的代号
	wire wire_visible;                          // 七项当前资格全部成立
	wire wire_fault;                            // 应到tick未到
	//-----------------输出信号-----------------//
	//用户接口
	reg request_o;                              // 注册重评请求
	reg fault_o;                                // 注册调度故障
	//---------------其他信号连线---------------//
	assign wire_shadow_less = {1'b0,reg_shadow} - {32'd0,1'b1}; // 模递减
	assign wire_increment = {1'b0,reg_generation} + {8'd0,i_change}; // 每沿最多增代一次
	assign wire_generation_next = wire_increment[7:0]; // 八位自然回绕
	assign flag_pending = &{reg_controls[2:1],reg_candidate_checks}; // 归约只读取已经登记的七个资格位
	assign wire_visible = ({reg_controls,reg_live_checks} == 5'b11101); // 共同撤销条件均在本沿登记
	assign wire_fault = !i_tick && flag_due;    // 本沿tick可恢复调度
	//---------------输出信号连线---------------//
	//用户接口
	assign o_generation = reg_generation;       // 当前内部版本
	assign o_request = request_o;               // 请求下一沿消费
	assign o_schedule_fault = fault_o;          // 调度监督状态
	assign o_publication = flag_selected & wire_visible; // 新载荷且最终有效才算发布
	assign o_current_valid = wire_visible;      // 寄存资格的短归约出口
	assign o_current_payload = wire_visible ? reg_raw : 442'd0; // 无效时屏蔽内部数据
	//-------------输出信号处理区域-------------//
	//用户接口
	// tick请求独立于候选流水。
	always @(posedge i_clk) begin
		if(i_rst) begin
			request_o <= 1'b0;                  // 复位不发请求
		end
		else begin
			request_o <= ({i_tick,i_blocked,i_suppress} == 3'b100); // 同域下一沿消费
		end
	end

	// 故障沿与原看门狗一致。
	always @(posedge i_clk) begin
		if(i_rst) begin
			fault_o <= 1'b0;                    // 复位不报故障
		end
		else begin
			fault_o <= wire_fault;              // 当前缺失状态
		end
	end
	//-------------主要任务处理区域-------------//
	// 同步推进缓存代号。
	always @(posedge i_clk) begin
		if(i_rst) begin
			reg_generation <= 8'd0;             // 复位必须同时冲刷上游候选
		end
		else begin
			reg_generation <= wire_generation_next; // 一沿最多变更一次
		end
	end

	// 倒计时区分启动装载和tick后间隔，零时饱和。
	always @(posedge i_clk) begin
		if(i_rst) begin
			reg_remaining <= C_CLOCKS_PER_MS[31:0]; // 首工作沿编号零，第P沿到期
		end
		else if(i_tick) begin
			reg_remaining <= LP_TICK_RELOAD[31:0]; // tick后第P沿到期
		end
		else if(flag_due) begin
			reg_remaining <= reg_remaining;     // 到期保持零，优先排除下溢
		end
		else begin
			reg_remaining <= reg_shadow;        // 非零时采纳已登记的递减结果
		end
	end

	// 提前登记主计数的下一值；到期后的辅助回绕不会被主计数采纳。
	always @(posedge i_clk) begin
		if(i_rst) begin
			reg_shadow <= LP_TICK_RELOAD[31:0]; // 主计数装P时预备P减一
		end
		else if(i_tick) begin
			reg_shadow <= LP_SHADOW_RELOAD[31:0]; // 主计数装P减一时预备P减二
		end
		else begin
			reg_shadow <= wire_shadow_less[31:0]; // 模递减，零时自然回绕
		end
	end

	// due等价于计数为零；无reset/tick且计数至多一时，下一沿到期。
	always @(posedge i_clk) begin
		flag_due <= ({i_rst,i_tick,(reg_remaining <= {31'd0,1'b1})} == 3'b001); // 同步复位和tick均译码为零
	end

	// 来源、调度与时间并行采样，前两项供候选和旧结果共用。
	always @(posedge i_clk) begin
		reg_controls[2] <= ({i_rst,i_blocked,i_suppress} == 3'b000); // 来源资格独立登记
	end
	// 调度资格与来源资格同行，保留原有拍数。
	always @(posedge i_clk) begin
		reg_controls[1] <= ({i_tick,flag_due} != 2'b01); // tick与到期比较
	end
	// 时间资格与其他资格同行，分开真实寄存目标。
	always @(posedge i_clk) begin
		reg_controls[0] <= (reg_sampled_now == i_now_ms); // 最终沿时间一致
	end

	// 候选的三项资格与原始载荷在同一沿冻结。
	always @(posedge i_clk) begin
		reg_candidate_checks <= {i_candidate_valid,(i_candidate_generation == wire_generation_next),(i_candidate_payload[63:0] == i_now_ms)}; // 存在、版本及时间分别登记
	end

	// 最终沿撤销同时覆盖旧有效结果和前沿已接纳候选。
	always @(posedge i_clk) begin
		reg_live_checks <= {i_change,(flag_pending | wire_visible)}; // 记录变化及存活依据，禁止解除本身不能复活
	end

	// 数据与其接纳资格在同一沿冻结。
	always @(posedge i_clk) begin
		reg_sampled_now <= i_now_ms;            // 只作一沿时间等值检查
	end

	// 冻结每个候选原始载荷，与接纳位同拍对齐。
	always @(posedge i_clk) begin
		reg_sampled_payload <= i_candidate_payload; // 无效输入也采样，但不能装入可见结果
	end

	// 登记本沿候选选择，用于发布事件区分。
	always @(posedge i_clk) begin
		flag_selected <= flag_pending;          // 发布脉冲由最终有效性共同限制
	end

	// 载荷写使能仅依赖前沿接纳，不再展开最终沿完整资格。
	always @(posedge i_clk) begin
		if(i_rst) begin
			reg_raw <= 442'd0;                  // 同步清除内部旧载荷
		end
		else if(flag_pending) begin
			reg_raw <= reg_sampled_payload;     // 前沿冻结数据与接纳资格对齐
		end
	end

endmodule
