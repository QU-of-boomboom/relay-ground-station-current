`timescale 1ns / 1ps
// 身份及配置归属判别，不包含新鲜度或持续告警。
module gs_quality_binding(
	input i_clk, // 本地时钟
	input i_rst, // 同步高有效复位
	input i_clear, // 配置提交冲刷
	input i_valid, // 输入事务有效
	input [223:0] i_active, // 当前控制身份和修订
	input [353:0] i_context, // 原结果上下文
	input [15:0] i_tag, // 原流水标签
	input [2:0] i_code, // 原数值质量码
	output o_valid, // 判别结果有效，包括拒绝
	output [1:0] o_binding, // 匹配零、身份错误一、配置错误二
	output [353:0] o_context, // 同笔证据上下文
	output [15:0] o_tag, // 同笔标签
	output [2:0] o_code // 原质量码，拒绝时不得用于告警
);
	wire flush; // 同步清除条件
	assign flush=i_rst | i_clear; // clear同沿输入不接受
	reg  flag_node=1'd0; // 节点字段相等
	reg  flag_session=1'd0; // 会话字段相等
	reg  flag_epoch=1'd0; // 运行代字段相等
	reg  flag_revision=1'd0; // 配置修订相等
	reg  valid_first=1'd0; // 接收事务有效
	reg [15:0] tag_first=16'd0; // 接收标签
	reg [2:0] code_first=3'd0; // 原数值质量码
	reg [353:0] context_first=354'd0; // 接受沿完整上下文
	reg  valid_o=1'd0; // 第三级结果有效
	reg [15:0] tag_o=16'd0; // 结果标签
	reg [2:0] code_o=3'd0; // 透传质量码
	reg [353:0] context_o=354'd0; // 结果证据载荷
	reg flag_identity_ok=1'd0; // 中间级合并节点、会话和运行代
	reg flag_config_bad=1'd0; // 中间级保存配置不匹配
	reg valid_second=1'd0; // 新增中间级事务有效
	reg [15:0] tag_second=16'd0; // 中间级标签
	reg [2:0] code_second=3'd0; // 中间级质量载荷
	reg [353:0] context_second=354'd0; // 中间级证据上下文
	reg binding_identity_o=1'd0; // 归属码低位表示身份错误
	reg binding_config_o=1'd0; // 归属码高位仅在身份匹配时表示配置错误
	assign o_valid=valid_o; // 输出桥接不新增周期
	assign o_binding={binding_config_o,binding_identity_o}; // 两个互斥错误位组成归属码
	assign o_context=context_o; // 输出桥接不新增周期
	assign o_tag=tag_o; // 输出桥接不新增周期
	assign o_code=code_o; // 输出桥接不新增周期
	// 寄存节点字段相等，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_node <= 1'd0; // 清空该级字段
		end else begin
			flag_node <= i_context[353:322] == i_active[223:192]; // 节点字段相等
		end
	end
	// 寄存会话字段相等，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_session <= 1'd0; // 清空该级字段
		end else begin
			flag_session <= i_context[321:258] == i_active[191:128]; // 会话字段相等
		end
	end
	// 寄存运行代字段相等，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_epoch <= 1'd0; // 清空该级字段
		end else begin
			flag_epoch <= i_context[257:194] == i_active[127:64]; // 运行代字段相等
		end
	end
	// 寄存配置修订相等，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_revision <= 1'd0; // 清空该级字段
		end else begin
			flag_revision <= i_context[193:130] == i_active[63:0]; // 配置修订相等
		end
	end
	// 寄存接收事务有效，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			valid_first <= 1'd0; // 清空该级字段
		end else begin
			valid_first <= i_valid; // 接收事务有效
		end
	end
	// 寄存接收标签，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			tag_first <= 16'd0; // 清空该级字段
		end else begin
			tag_first <= i_tag; // 接收标签
		end
	end
	// 寄存原数值质量码，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			code_first <= 3'd0; // 清空该级字段
		end else begin
			code_first <= i_code; // 原数值质量码
		end
	end
	// 寄存接受沿完整上下文，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			context_first <= 354'd0; // 清空该级字段
		end else begin
			context_first <= i_context; // 接受沿完整上下文
		end
	end
	// 寄存第三级结果有效，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			valid_o <= 1'd0; // 清空该级字段
		end else begin
			valid_o <= valid_second; // 第三级结果有效
		end
	end
	// 寄存结果标签，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			tag_o <= 16'd0; // 清空该级字段
		end else begin
			tag_o <= tag_second; // 结果标签
		end
	end
	// 寄存透传质量码，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			code_o <= 3'd0; // 清空该级字段
		end else begin
			code_o <= code_second; // 透传质量码
		end
	end
	// 寄存结果证据载荷，随同步清除撤销本级历史。
	always @(posedge i_clk) begin
		if(flush) begin
			context_o <= 354'd0; // 清空该级字段
		end else begin
			context_o <= context_second; // 结果证据载荷
		end
	end
	// 归属低位独立寄存身份拒绝条件。
	always @(posedge i_clk) begin
		if(flush) begin
			binding_identity_o <= 1'd0; // 复位清除身份编码
		end else begin
			binding_identity_o <= !flag_identity_ok; // 身份任一字段不匹配即置位
		end
	end
	// 身份不匹配时必须抑制配置拒绝位。
	always @(posedge i_clk) begin
		if(flush) begin
			binding_config_o <= 1'd0; // 复位清除配置编码
		end else begin
			binding_config_o <= flag_identity_ok & flag_config_bad; // 实现身份优先级
		end
	end
	// 合并三个身份相等标记。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_identity_ok <= 1'd0; // 清除本级历史
		end else begin
			flag_identity_ok <= &{flag_node, flag_session, flag_epoch}; // 三个一位标记全部相等才通过
		end
	end
	// 保存配置不匹配结果。
	always @(posedge i_clk) begin
		if(flush) begin
			flag_config_bad <= 1'd0; // 清除本级历史
		end else begin
			flag_config_bad <= !flag_revision; // 保存配置不匹配结果
		end
	end
	// 将事务有效位对齐到新中间级。
	always @(posedge i_clk) begin
		if(flush) begin
			valid_second <= 1'd0; // 清除本级历史
		end else begin
			valid_second <= valid_first; // 将事务有效位对齐到新中间级
		end
	end
	// 推进事务标签。
	always @(posedge i_clk) begin
		if(flush) begin
			tag_second <= 16'd0; // 清除本级历史
		end else begin
			tag_second <= tag_first; // 推进事务标签
		end
	end
	// 推进原始质量码。
	always @(posedge i_clk) begin
		if(flush) begin
			code_second <= 3'd0; // 清除本级历史
		end else begin
			code_second <= code_first; // 推进原始质量码
		end
	end
	// 推进完整证据元数据。
	always @(posedge i_clk) begin
		if(flush) begin
			context_second <= 354'd0; // 清除本级历史
		end else begin
			context_second <= context_first; // 推进完整证据元数据
		end
	end
endmodule
