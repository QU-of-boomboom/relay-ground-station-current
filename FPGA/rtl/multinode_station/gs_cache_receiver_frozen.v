`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/05 14:36:36
// Design Name:     gs_cache_receiver_frozen
// Module Name:     gs_cache_receiver_frozen
// Description:     gs_cache_receiver_frozen_spec.md
// Simulations:     sim/tb_gs_cache_receiver_equivalence.v
//
// Referrences:     None
//
// Dependencies:    None
//
// Version:         V1.0
// Revision Date:   2026/10/05 14:36:36
// History:
// Time             Version     Revised by        Contents
// 2026/10/05       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月05日
// 设计名称:        gs_cache_receiver_frozen
// 模块名称:        gs_cache_receiver_frozen
// 模块说明:        gs_cache_receiver_frozen_spec.md
// 仿真工程:        sim/tb_gs_cache_receiver_equivalence.v
//
// 参考资料:        None
//
// 依赖文件:        None
//
// 当前版本:        V1.0
// 修订日期:        2026年10月05日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月05日   V1.0        Relay project              创建文件

module gs_cache_receiver_frozen(
	//-----------------全局信号-----------------//
	input i_clk,                                // 判定流水共同采样时钟
	input i_rst,                                // 同步清除在途控制
	//-----------------用户接口-----------------//
	input i_cancel,                             // 当前配置取消事件
	input i_inhibit,                            // 当拍禁止新的入口请求
	input i_valid,                              // 原始统计等待接收
	input [371:0] i_packet,                     // 统计字段和原上下文
	input [438:0] i_cache,                      // 银行当前完整快照
	input [223:0] i_active,                     // 控制侧合法身份及修订
	input [8:0] i_window,                       // 当前合法窗口容量
	input [63:0] i_now_ms,                      // 当前单调本地时间
	output o_ready,                             // 接收机会复位取消另行优先
	output [439:0] o_transaction,               // 送银行的完整原子事务
	output o_done,                              // 银行提交沿后完成
	output [3:0] o_receipt                      // 非完成时编码为零
);
	//--------------模块实例化信号--------------//
	//----------------寄存器信号----------------//
	reg [5:0] reg_pipeline;                     // 六个在途寄存位置
	reg [371:0] reg_packet;                     // R沿直接冻结原始快照
	reg [438:0] reg_cache;                      // R沿直接冻结比较基准
	reg [223:0] reg_active;                     // R沿直接冻结可信配置归属
	reg [8:0] reg_window;                       // R沿直接冻结容量门限
	reg [63:0] reg_now;                         // 未来时间比较不得随等待刷新
	reg [13:0] reg_checks;                      // 各字段比较事实同行
	reg [3:0] reg_receipt;                      // R加五登记优先级结论
	reg [3:0] reg_structure;                    // 结构校验组编码
	reg [3:0] reg_identity;                     // 身份修订组编码
	reg [3:0] reg_temporal;                     // 窗口及来源时间组编码
	reg [3:0] reg_priority_high;                // 结构及身份合并编码
	reg [3:0] reg_priority_low;                 // 序号及来源合并编码
	wire [877:0] wire_replacements;             // 从本笔冻结入口组合生成接受和拒绝状态
	reg flag_transaction;                     // R加六仅登记银行写许可
	reg reg_write;                              // R加三预判本笔是否写银行
	reg [438:0] reg_selected;                   // R加三选定接受或拒绝数据
	//-----------------标志信号-----------------//
	wire flag_accept;                           // 上沿未废弃请求启动主流水
	reg flag_candidate;                         // 登记上沿候选请求
	reg flag_abort;                             // 登记上沿复位或取消
	//-----------------编码信号-----------------//
	reg [3:0] enc_sequence;                     // 重复旧序号组编码
	//-----------------其他信号-----------------//
	//-----------------输出信号-----------------//
	//用户接口
	reg done_o;                                 // 结果完成脉冲寄存
	reg ready_o;                                // 单拍入口机会寄存
	//---------------其他信号连线---------------//
	assign flag_accept = ({flag_candidate,flag_abort} == 2'b10); // 只启动未被同沿控制废弃的候选
	//---------------输出信号连线---------------//
	//用户接口
	assign o_ready = ready_o & ~i_inhibit;      // 禁止当拍撤销机会复位取消在采样沿优先
	assign o_transaction = ({i_rst,i_cancel} == 2'd0) ?
		(flag_transaction ? {1'b1,reg_selected} : 440'd0) : 440'd0; // 冻结选择保持到银行消费，无许可时完整清零
	assign o_done = done_o;                     // 单拍完成事件
	assign o_receipt = done_o ? reg_receipt : 4'd0; // 无完成时编码不可消费
	//-------------输出信号处理区域-------------//
	//用户接口
	// 所有正常分类均在提交沿给完成事件，取消无完成。
	always @(posedge i_clk) begin
		done_o <= ({i_rst,i_cancel,reg_pipeline[5]} == 3'b001); // 严格对应T沿
	end

	// 空闲且没有刚发出的机会或候选时才登记下一次机会。
	always @(posedge i_clk) begin
		if(i_rst | i_cancel) begin
			ready_o <= 1'b0;                    // 控制采样后关闭机会
		end
		else begin
			ready_o <= ({reg_pipeline,ready_o,flag_candidate} == 8'd0); // 入口未入主流水时也禁止重开
		end
	end

	//-------------主要任务处理区域-------------//
	// 候选和废弃分别登记以形成真实准入边界。
	always @(posedge i_clk) begin
		flag_candidate <= i_valid & o_ready;    // 包含当拍inhibit资格
	end

	// 同沿控制优先于表面valid与ready相交。
	always @(posedge i_clk) begin
		flag_abort <= i_rst | i_cancel;         // 下一沿阻止被废弃请求复活
	end

	// 控制令牌驱动固定六拍流水，无提交沿接收旁路。
	always @(posedge i_clk) begin
		if(i_rst | i_cancel) begin
			reg_pipeline <= 6'd0;               // 同步撤销全部在途位置
		end
		else begin
			reg_pipeline <= {reg_pipeline[4:0],flag_accept}; // 接收令牌逐沿移向提交
		end
	end

	// 冻结原始统计，后续输入不能覆盖本笔证据。
	always @(posedge i_clk) begin
		if(i_valid & o_ready) begin
			reg_packet <= i_packet;   // 握手R沿直接捕获，单在途期间保持
		end
	end

	// 入口仅取当前银行快照用于本笔判定。
	always @(posedge i_clk) begin
		if(i_valid & o_ready) begin
			reg_cache <= i_cache;     // 序号与来源下限同行
		end
	end

	// 活动配置归属随握手固定。
	always @(posedge i_clk) begin
		if(i_valid & o_ready) begin
			reg_active <= i_active;   // 保持该笔身份及修订
		end
	end

	// 容量配置保持到此次判定结束。
	always @(posedge i_clk) begin
		if(i_valid & o_ready) begin
			reg_window <= i_window;   // 不使用后来改变的容量
		end
	end

	// 冻结接收时刻，等待不会修正未来来源。
	always @(posedge i_clk) begin
		if(i_valid & o_ready) begin
			reg_now <= i_now_ms;         // 未来比较使用R沿时间
		end
	end

	// 比较事实连续登记，只有对应令牌允许后级消费。
	always @(posedge i_clk) begin
		reg_checks[13] <= ({reg_packet[1],reg_packet[65]} == 2'b11); // 已知来源超出有符号时间范围
		reg_checks[12] <= (reg_packet[362:354] > reg_packet[371:363]); // 送达量不得超过总量
		reg_checks[11] <= (reg_packet[371:363] > 9'd256); // 原始统计计数上限
		reg_checks[10] <= (reg_packet[193:130] == 64'd0); // 原始修订必须非零
		reg_checks[9] <= (reg_packet[257:194] == 64'd0); // 零epoch不能表示有效启动周期
		reg_checks[8] <= (reg_packet[321:258] == 64'd0); // 会话标识零不属于有效归属
		reg_checks[7] <= (reg_packet[353:322] == 32'd0); // 节点编号零在协议中保留
		reg_checks[6] <= (reg_packet[353:194] != reg_active[223:64]); // 先核对全部身份字段
		reg_checks[5] <= (reg_packet[193:130] != reg_active[63:0]); // 再核对配置修订
		reg_checks[4] <= reg_cache[438] & (reg_packet[129:66] == reg_cache[129:66]); // 同身份的重复统计
		reg_checks[3] <= reg_cache[438] & (reg_packet[129:66] < reg_cache[129:66]); // 无回绕的旧结果序号
		reg_checks[2] <= (reg_packet[371:363] > reg_window); // 统计总量超过当前窗口
		reg_checks[1] <= reg_packet[1] & (reg_packet[65:2] > reg_now); // 与接收时刻比较未来来源
		reg_checks[0] <= reg_packet[1] & reg_cache[436] & (reg_packet[65:2] < reg_cache[435:372]); // 已知来源不得倒退
	end

	// R加三四组各自编码，零表示本组未命中。
	always @(posedge i_clk) begin
		reg_structure <= (reg_checks[13:7] != 7'b0000000) ? 4'b0110 : 4'b0000; // 结构非法拥有全局最高优先级
	end

	// 身份与修订构成同一优先组。
	always @(posedge i_clk) begin
		reg_identity <= reg_checks[6] ? 4'b0100 : (reg_checks[5] ? 4'b0101 : 4'b0000); // 身份先于修订
	end

	// 序号组只给出重复和旧序号分类。
	always @(posedge i_clk) begin
		enc_sequence <= reg_checks[4] ? 4'b0010 : (reg_checks[3] ? 4'b0011 : 4'b0000); // 重复先于旧序号
	end

	// 最低优先组包含窗口及来源检查并提供默认接受。
	always @(posedge i_clk) begin
		reg_temporal <= (reg_checks[2:1] != 2'b00) ? 4'b0110 : (reg_checks[0] ? 4'b0111 : 4'b0001); // 窗口未来错误先于倒退否则接受
	end

	// R加四合并相邻组，不在同一沿贯穿完整优先树。
	always @(posedge i_clk) begin
		reg_priority_high <= (reg_structure != 4'b0000) ? reg_structure : reg_identity; // 高组保持结构先于身份
	end

	// 序号命中时必须遮蔽低优先级时间错误。
	always @(posedge i_clk) begin
		reg_priority_low <= (enc_sequence != 4'b0000) ? enc_sequence : reg_temporal; // 低组保持序号先于来源
	end

	// R加五登记最终结论，令牌尚未允许对外提交。
	always @(posedge i_clk) begin
		reg_receipt <= (reg_priority_high != 4'b0000) ? reg_priority_high : reg_priority_low; // 高组未命中才取低组
	end

	// 单在途入口从R保持到完成；选取阶段已晚于冻结至少两拍，无需再复制878位。
	assign wire_replacements = {{1'b1,1'b0,(reg_packet[1] | reg_cache[436]),(reg_packet[1] ? reg_packet[65:2] : reg_cache[435:372]),reg_packet[371:66],(reg_packet[1] ? reg_packet[65:2] : 64'd0),reg_packet[1:0]},{reg_cache[438],1'b1,reg_cache[436:0]}}; // 未知来源保留下限，拒绝保留旧缓存

	// R加三并行登记写策略；身份或结构错误优先于重复旧序号。
	always @(posedge i_clk) begin
		reg_write <= (reg_checks[13:5] != 9'b000000000) | (reg_checks[4:3] == 2'b00); // 只有未被高优先级拒绝覆盖的重复旧序号免写
	end

	// R加三并行选择完整数据；全部事实为零才是接受。
	always @(posedge i_clk) begin
		reg_selected <= (reg_checks == 14'b00000000000000) ? wire_replacements[877:439] : wire_replacements[438:0]; // 仍保留439位选择寄存边界，避免把数据选择并到最终事务沿
	end

	// R加六登记许可；单在途保证reg_selected到R加七仍属本笔。
	always @(posedge i_clk) begin
		if({i_rst,i_cancel,reg_pipeline[4],reg_write} == 4'b0011) begin
			flag_transaction <= 1'b1;          // 仅正常在途且非免写分类生成事务
		end
		else begin
			flag_transaction <= 1'b0;          // 许可清零同时屏蔽整个事务载荷
		end
	end
	//--------------模块实例化区域--------------//
endmodule
