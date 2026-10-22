`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/05 14:36:36
// Design Name:     gs_evidence_cache_bank
// Module Name:     gs_evidence_cache_bank
// Description:     gs_evidence_cache_bank_spec.md
// Simulations:     sim/tb_gs_evidence_cache_bank.v
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
// 设计名称:        gs_evidence_cache_bank
// 模块名称:        gs_evidence_cache_bank
// 模块说明:        gs_evidence_cache_bank_spec.md
// 仿真工程:        sim/tb_gs_evidence_cache_bank.v
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

module gs_evidence_cache_bank(
	//-----------------全局信号-----------------//
	input i_clk,                                // 缓存事务采样时钟
	input i_rst,                                // 同步高有效清空缓存
	//-----------------用户接口-----------------//
	input [439:0] i_transaction,                // 提交许可与完整新状态同行
	output [438:0] o_cache                      // 所有缓存字段的寄存快照
);
	//--------------模块实例化信号--------------//
	//----------------寄存器信号----------------//
	//-----------------标志信号-----------------//
	//-----------------其他信号-----------------//
	//-----------------输出信号-----------------//
	//用户接口
	reg [438:0] cache_o;                        // 证据序号下限与资格共同存储
	//---------------其他信号连线---------------//
	//---------------输出信号连线---------------//
	//用户接口
	assign o_cache = cache_o;                   // 读口直接观察完整寄存状态
	//-------------输出信号处理区域-------------//
	//用户接口
	// 复位优先于提交，无事务时所有字段共同保持。
	always @(posedge i_clk) begin
		if(i_rst) begin
			cache_o <= 439'd0;                  // 清空证据及来源下限
		end
		else if(i_transaction[439]) begin
			cache_o <= i_transaction[438:0];    // 一次装入所有缓存字段
		end
	end
	//--------------模块实例化区域--------------//
endmodule
