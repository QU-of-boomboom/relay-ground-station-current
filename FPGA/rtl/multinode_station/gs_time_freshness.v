`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/03 14:36:36
// Design Name:     gs_time_freshness
// Module Name:     gs_time_freshness
// Description:     gs_time_freshness_spec.md
// Simulations:     sim/tb_gs_time_freshness.v
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
// 设计名称:        gs_time_freshness
// 模块名称:        gs_time_freshness
// 模块说明:        gs_time_freshness_spec.md
// 仿真工程:        sim/tb_gs_time_freshness.v
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

module gs_time_freshness
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 本地流水时钟
	input i_rst,                                // 同步高有效复位
	input i_clear,                              // 同步冲刷，丢弃同沿输入

	//-----------------用户接口-----------------//
	input i_valid,                              // 输入快照有效
	input [15:0]i_tag,                          // 核对标签，不代替完整身份
	input [63:0]i_now_ms,                       // 同域单调当前时间
	input [63:0]i_observation_ms,               // 可信来源时间
	input [63:0]i_max_age_ms,                   // 正数过期阈值
	input i_time_known,                         // 来源时间是否已知
	output o_valid,                             // 结果事务有效，含拒绝
	output [15:0]o_tag,                         // 原事务标签
	output [1:0]o_status,                       // 新鲜零、过期一、未知二、非法三
	output o_age_valid,                         // 年龄是否有意义
	output [63:0]o_age_ms,                      // 非法或未知时为零
	output [63:0]o_evaluated_ms                 // 此判定采样的当前时间
);

	//----------------寄存器信号----------------//
	reg [32:0]reg_delta_low;                    // 低位减法及借位
	reg [32:0]reg_delta_high;                   // 高位独立减法及借位
	reg [3:0]reg_bad_first;                     // 分开采样时间范围及零阈值
	reg reg_unknown_first;                      // 来源未知预判
	reg [81:0]reg_meta_first;                   // 接受沿完整核对元数据
	reg [63:0]reg_maximum_first;                // 接受沿阈值
	reg [64:0]reg_age_second;                   // 完整无符号差及最终借位
	reg reg_global_second;                      // 汇总全局参数越界
	reg reg_origin_second;                      // 仅已知来源的范围错误
	reg reg_unknown_second;                     // 比较沿的未知状态
	reg [81:0]reg_meta_second;                  // 借位修正沿事务标记
	reg [63:0]reg_maximum_second;               // 比较所需阈值副本
	reg [2:0]reg_bad_third;                     // 三个独立非法原因
	reg reg_allowed_third;                      // 合法已知年龄预判
	reg [63:0]reg_age_third;                    // 比较沿的年龄数值
	reg [81:0]reg_meta_third;                   // 阈值判定沿元数据
	reg reg_stale_third;                        // 年龄达到阈值
	reg reg_expired_fourth;                     // 仅合法已知的过期结果
	reg reg_high_fourth;                        // 状态高位预判
	reg [63:0]reg_age_fourth;                   // 编码前屏蔽无效年龄
	reg reg_allowed_fourth;                     // 编码沿年龄有效标记
	reg [81:0]reg_meta_fourth;                  // 新增编码级的事务元数据
	//-----------------标志信号-----------------//
	reg flag_invalid_fourth;                    // 编码前汇总非法状态

	//-----------------其他信号-----------------//
	// 同步控制及借位修正
	wire flush;                                 // 全级清除条件
	wire [32:0]corrected_high;                  // 保留最终借位的高位修正

	//-----------------输出信号-----------------//
	//用户接口
	reg valid_o;                                // 输出事务有效
	reg [15:0]tag_o;                            // 输出原事务标签
	reg status_high_o;                          // 新鲜度编码高位
	reg status_low_o;                           // 新鲜度编码低位
	reg age_valid_o;                            // 输出年龄有效
	reg [63:0]age_ms_o;                         // 最终提交的毫秒差值
	reg [63:0]evaluated_ms_o;                   // 输出采样时刻
	//---------------其他信号连线---------------//
	assign flush = i_rst | i_clear;             // 同沿输入被丢弃
	assign corrected_high = reg_delta_high - {32'd0, reg_delta_low[32]}; // 高位保留借位，不做有符号推断

	//---------------输出信号连线---------------//
	//用户接口
	assign o_valid = valid_o;                   // 驱动本拍结果可消费指示
	assign o_tag = tag_o;                       // 交付与原请求对应的标签
	assign o_status = {status_high_o, status_low_o}; // 拼合高低两位形成四态判定
	assign o_age_valid = age_valid_o;           // 向消费者声明毫秒差是否可信
	assign o_age_ms = age_ms_o;                 // 连接已完成屏蔽的64位年龄
	assign o_evaluated_ms = evaluated_ms_o;     // 返回判断使用的当前时间快照

	//-------------输出信号处理区域-------------//
	//用户接口
	// 输出事务有效：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			valid_o <= 1'd0;                    // 禁止清除沿结果被消费
		end else begin
			valid_o <= reg_meta_fourth[81];     // 提交随元数据传播的事务有效位
		end
	end

	// 输出原事务标签：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			tag_o <= 16'd0;                     // 归零用户标签输出
		end else begin
			tag_o <= reg_meta_fourth[80:65];    // 取出接受时的十六位标识
		end
	end

	// 新鲜度编码高位：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			status_high_o <= 1'd0;              // 消除未知和非法类别位
		end else begin
			status_high_o <= reg_high_fourth;   // 复制不可提供年龄时置位的类别
		end
	end

	// 新鲜度编码低位：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			status_low_o <= 1'd0;               // 撤销过期和错误结果位
		end else begin
			status_low_o <= flag_invalid_fourth | reg_expired_fourth; // 将参数拒绝或合法过期合入编码最低位
		end
	end

	// 输出年龄有效：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			age_valid_o <= 1'd0;                // 撤回差值可信标志
		end else begin
			age_valid_o <= reg_allowed_fourth;  // 返回上一级的合法且已知判定
		end
	end

	// 最终提交的毫秒差值：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			age_ms_o <= 64'd0;                  // 清空对外可见的时间差
		end else begin
			age_ms_o <= reg_age_fourth;         // 传出已屏蔽非法与未知数据的年龄
		end
	end

	// 输出采样时刻：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			evaluated_ms_o <= 64'd0;            // 移除上笔结果适用时刻
		end else begin
			evaluated_ms_o <= reg_meta_fourth[64:1]; // 保留本事务采样的now供消费者核对
		end
	end

	//-------------主要任务处理区域-------------//
	// 低位减法及借位：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_delta_low <= 33'd0;             // 撤销低字减法历史
		end else begin
			reg_delta_low <= {1'b0, i_now_ms[31:0]} - {1'b0, i_observation_ms[31:0]}; // 计算低字差并在第32位留下借位
		end
	end

	// 高位独立减法及借位：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_delta_high <= 33'd0;            // 清空高字算术寄存
		end else begin
			reg_delta_high <= {1'b0, i_now_ms[63:32]} - {1'b0, i_observation_ms[63:32]}; // 先独立计算高字差，下一拍修正低字借位
		end
	end

	// 分开采样时间范围及零阈值：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_bad_first <= 4'd0;              // 擦除接受沿参数范围标记
		end else begin
			reg_bad_first <= {i_now_ms[63], i_max_age_ms[63], (i_max_age_ms == 64'd0), i_observation_ms[63]}; // 分别保存now越界、上限越界、零上限和来源越界
		end
	end

	// 来源未知预判：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_unknown_first <= 1'd0;          // 撤销最前级缺失时间标志
		end else begin
			reg_unknown_first <= !i_time_known; // 将来源未提供时间的情况编码为一位
		end
	end

	// 接受沿完整核对元数据：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_meta_first <= 82'd0;            // 丢弃当前刚接受的事务头
		end else begin
			reg_meta_first <= {i_valid, i_tag, i_now_ms, i_time_known}; // 把valid、tag、now、known打包在同一接受沿
		end
	end

	// 接受沿阈值：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_maximum_first <= 64'd0;         // 消除采样级旧期限
		end else begin
			reg_maximum_first <= i_max_age_ms;  // 锁存本次使用的max_age，不随后续输入改变
		end
	end

	// 完整无符号差及最终借位：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_age_second <= 65'd0;            // 清除完整差值和下溢证据
		end else begin
			reg_age_second <= {corrected_high, reg_delta_low[31:0]}; // 拼接33位修正高字与32位低字，保留最终借位
		end
	end

	// 汇总全局参数越界：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_global_second <= 1'd0;          // 取消全局时间参数拒绝
		end else begin
			reg_global_second <= |reg_bad_first[3:1]; // 归并当前时间及期限的三项非法原因
		end
	end

	// 仅已知来源的范围错误：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_origin_second <= 1'd0;          // 撤销已知来源范围拒绝
		end else begin
			reg_origin_second <= reg_bad_first[0] & reg_meta_first[0]; // 仅在known为真时采用来源最高位错误
		end
	end

	// 比较沿的未知状态：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_unknown_second <= 1'd0;         // 冲掉比较前缺失标志
		end else begin
			reg_unknown_second <= reg_unknown_first; // 把来源未知状态带到有效年龄判定级
		end
	end

	// 借位修正沿事务标记：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_meta_second <= 82'd0;           // 丢弃借位修正阶段的事务头
		end else begin
			reg_meta_second <= reg_meta_first;  // 使身份核对信息与65位差值同步前进
		end
	end

	// 比较所需阈值副本：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_maximum_second <= 64'd0;        // 擦除比较级阈值历史
		end else begin
			reg_maximum_second <= reg_maximum_first; // 将对应期限对齐到年龄比较输入
		end
	end

	// 三个独立非法原因：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_bad_third <= 3'd0;              // 清空最终三类拒绝原因
		end else begin
			reg_bad_third <= {reg_global_second, reg_origin_second, reg_age_second[64] & reg_meta_second[0]}; // 分开保留参数错误、来源范围错误和已知未来时间
		end
	end

	// 合法已知年龄预判：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_allowed_third <= 1'd0;          // 拒绝冲刷后的旧年龄
		end else begin
			reg_allowed_third <= {reg_global_second, reg_origin_second, reg_age_second[64], reg_unknown_second} == 4'd0; // 仅四项阻断因素全零时允许提供数值年龄
		end
	end

	// 比较沿的年龄数值：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_age_third <= 64'd0;             // 撤销编码前的低64位差
		end else begin
			reg_age_third <= reg_age_second[63:0]; // 移交差值主体，借位已由独立条件处理
		end
	end

	// 阈值判定沿元数据：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_meta_third <= 82'd0;            // 清除阈值输出级携带信息
		end else begin
			reg_meta_third <= reg_meta_second;  // 把事务属性推进到状态判定对应的位置
		end
	end

	// 年龄达到阈值：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_stale_third <= 1'd0;            // 解除旧数据的到期标记
		end else begin
			reg_stale_third <= reg_age_second[63:0] >= reg_maximum_second; // 年龄等于或大于期限时立即登记到期
		end
	end

	// 编码前汇总非法状态：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			flag_invalid_fourth <= 1'd0;        // 撤回提交前错误类别
		end else begin
			flag_invalid_fourth <= |reg_bad_third; // 任一非法原因成立便准备INVALID的低位
		end
	end

	// 仅合法已知的过期结果：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_expired_fourth <= 1'd0;         // 丢弃提交前有效过期项
		end else begin
			reg_expired_fourth <= reg_stale_third & reg_allowed_third; // 仅把合法且有来源时间的到期结果用于编码
		end
	end

	// 状态高位预判：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_high_fourth <= 1'd0;            // 清除提交前类别高位
		end else begin
			reg_high_fourth <= !reg_allowed_third; // 不能输出年龄时预置UNKNOWN或INVALID的共同位
		end
	end

	// 编码前屏蔽无效年龄：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_age_fourth <= 64'd0;            // 擦除对外提交前差值
		end else begin
			reg_age_fourth <= reg_allowed_third ? reg_age_third : 64'd0; // 年龄无效则强制清零，合法时保持实际毫秒数
		end
	end

	// 编码沿年龄有效标记：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_allowed_fourth <= 1'd0;         // 取消输出前年龄许可
		end else begin
			reg_allowed_fourth <= reg_allowed_third; // 延迟年龄许可，使其与屏蔽后的数值一致
		end
	end

	// 新增编码级的事务元数据：共享同步冲刷优先。
	always@(posedge i_clk)begin
		if(flush)begin
			reg_meta_fourth <= 82'd0;           // 清掉最后一级在途事务
		end else begin
			reg_meta_fourth <= reg_meta_third;  // 新增寄存边界携带原tag和采样时刻
		end
	end

endmodule
