module vga_timing#(
	parameter H_ACTIVE = 16'd1280,  	//thời gian tích cực ngang (điểm ảnh)
	parameter H_FP 	   = 16'd110,		//hiên trước ngang - front porch (điểm ảnh)
	parameter H_SYNC   = 16'd40,   		//thời gian đồng bộ ngang (điểm ảnh)
	parameter H_BP	   = 16'd220,  		//hiên sau ngang - back porch (điểm ảnh)
	parameter V_ACTIVE = 16'd720,		//thời gian tích cực dọc (dòng)
	parameter V_FP     = 16'd5,  		//hiên trước dọc - front porch (dòng)
	parameter V_SYNC   = 16'd5,  		//thời gian đồng bộ dọc (dòng)
	parameter V_BP     = 16'd20, 		//hiên sau dọc - back porch (dòng)
	parameter HS_POL   = 1'b1,   		//cực tính đồng bộ ngang, 1 : DƯƠNG, 0 : ÂM;
	parameter VS_POL   = 1'b1    		//cực tính đồng bộ dọc, 1 : DƯƠNG, 0 : ÂM;
)(
	input                 clk,           //clock điểm ảnh
	input                 rst,           //tín hiệu reset tích cực mức cao
	output                hs,            //đồng bộ ngang (horizontal sync)
	output                vs,            //đồng bộ dọc (vertical sync)
	output                de,            //video hợp lệ

	output reg [11:0] active_x,           //vị trí video theo trục x
	output reg [11:0] active_y            //vị trí video theo trục y
	
	);

	localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;//tổng thời gian ngang (điểm ảnh)
	localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;//tổng thời gian dọc (dòng)


/***** ĐỂ THAM KHẢO *******/

//VIDEO_1280_720
///-----------------------------------------------------------------------
/*
parameter H_ACTIVE = 16'd1280;           //thời gian tích cực ngang (điểm ảnh)
parameter H_FP = 16'd110;                //hiên trước ngang - front porch (điểm ảnh)
parameter H_SYNC = 16'd40;               //thời gian đồng bộ ngang (điểm ảnh)
parameter H_BP = 16'd220;                //hiên sau ngang - back porch (điểm ảnh)
parameter V_ACTIVE = 16'd720;            //thời gian tích cực dọc (dòng)
parameter V_FP  = 16'd5;                 //hiên trước dọc - front porch (dòng)
parameter V_SYNC  = 16'd5;               //thời gian đồng bộ dọc (dòng)
parameter V_BP  = 16'd20;                //hiên sau dọc - back porch (dòng)
parameter HS_POL = 1'b1;                 //cực tính đồng bộ ngang, 1 : DƯƠNG, 0 : ÂM;
parameter VS_POL = 1'b1;                 //cực tính đồng bộ dọc, 1 : DƯƠNG, 0 : ÂM;
parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;//tổng thời gian ngang (điểm ảnh)
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;//tổng thời gian dọc (dòng)
*/

//VIDEO_1280_720_30_DMT
/*//-----------------------------------------------------------------------
parameter H_ACTIVE = 16'd1280;           //thời gian tích cực ngang (điểm ảnh)
parameter H_FP = 16'd1760;                //hiên trước ngang - front porch (điểm ảnh)
parameter H_SYNC = 16'd40;               //thời gian đồng bộ ngang (điểm ảnh)
parameter H_BP = 16'd220;                //hiên sau ngang - back porch (điểm ảnh)
parameter V_ACTIVE = 16'd720;            //thời gian tích cực dọc (dòng)
parameter V_FP  = 16'd5;                 //hiên trước dọc - front porch (dòng)
parameter V_SYNC  = 16'd5;               //thời gian đồng bộ dọc (dòng)
parameter V_BP  = 16'd20;                //hiên sau dọc - back porch (dòng)
parameter HS_POL = 1'b1;                 //cực tính đồng bộ ngang, 1 : DƯƠNG, 0 : ÂM;
parameter VS_POL = 1'b1;                 //cực tính đồng bộ dọc, 1 : DƯƠNG, 0 : ÂM;

parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;//tổng thời gian ngang (điểm ảnh)
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;//tổng thời gian dọc (dòng)
*/

/*
//VIDEO_800x600
///-----------------------------------------------------------------------
parameter H_ACTIVE = 16'd800;           //thời gian tích cực ngang (điểm ảnh)
parameter H_FP = 16'd40;                //hiên trước ngang - front porch (điểm ảnh)
parameter H_SYNC = 16'd128;               //thời gian đồng bộ ngang (điểm ảnh)
parameter H_BP = 16'd88;                //hiên sau ngang - back porch (điểm ảnh)
parameter V_ACTIVE = 16'd600;            //thời gian tích cực dọc (dòng)
parameter V_FP  = 16'd1;                 //hiên trước dọc - front porch (dòng)
parameter V_SYNC  = 16'd4;               //thời gian đồng bộ dọc (dòng)
parameter V_BP  = 16'd23;                //hiên sau dọc - back porch (dòng)
parameter HS_POL = 1'b1;                 //cực tính đồng bộ ngang, 1 : DƯƠNG, 0 : ÂM;
parameter VS_POL = 1'b1;                 //cực tính đồng bộ dọc, 1 : DƯƠNG, 0 : ÂM;
parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;//tổng thời gian ngang (điểm ảnh)
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;//tổng thời gian dọc (dòng)
*/

reg hs_reg;                      //thanh ghi đồng bộ ngang
reg vs_reg;                      //thanh ghi đồng bộ dọc
reg[11:0] h_cnt;                 //bộ đếm ngang
reg[11:0] v_cnt;                 //bộ đếm dọc

reg h_active;                    //vùng video tích cực theo ngang
reg v_active;                    //vùng video tích cực theo dọc
assign hs = hs_reg;
assign vs = vs_reg;
assign de = h_active & v_active;


//đếm cột
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_cnt <= 12'd0;
	else if(h_cnt == H_TOTAL - 1)//giá trị tối đa của bộ đếm ngang
		h_cnt <= 12'd0;
	else
		h_cnt <= h_cnt + 12'd1;
end
//đếm điểm ảnh
always@(posedge clk)
begin
	if(h_cnt >= H_FP + H_SYNC + H_BP)//vùng video tích cực theo ngang
		active_x <= h_cnt - (H_FP[11:0] + H_SYNC[11:0] + H_BP[11:0]);
	else
		active_x <= active_x;
end
always@(posedge clk)
begin	
	if(v_cnt >= V_FP + V_SYNC + V_BP)//vùng video tích cực theo ngang
		active_y <= v_cnt - (V_FP[11:0] + V_SYNC[11:0] + V_BP[11:0]);
	else
		active_y <= active_y;
end
//đếm hàng
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_cnt <= 12'd0;
	else if(h_cnt == H_FP  - 1)//thời gian đồng bộ ngang
		if(v_cnt == V_TOTAL - 1)//giá trị tối đa của bộ đếm dọc
			v_cnt <= 12'd0;
		else
			v_cnt <= v_cnt + 12'd1;
	else
		v_cnt <= v_cnt;
end
//SINH HS
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		hs_reg <= 1'b0;
	else if(h_cnt == H_FP - 1)//bắt đầu đồng bộ ngang
		hs_reg <= HS_POL;
	else if(h_cnt == H_FP + H_SYNC - 1)//kết thúc đồng bộ ngang
		hs_reg <= ~hs_reg;
	else
		hs_reg <= hs_reg;
end
//Cột hợp lệ
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_active <= 1'b0;
	else if(h_cnt == H_FP + H_SYNC + H_BP - 1)//bắt đầu vùng tích cực ngang
		h_active <= 1'b1;
	else if(h_cnt == H_TOTAL - 1)//kết thúc vùng tích cực ngang
		h_active <= 1'b0;
	else
		h_active <= h_active;
end
//SINH VS
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		vs_reg <= 1'd0;
	else if((v_cnt == V_FP - 1) && (h_cnt == H_FP - 1))//bắt đầu đồng bộ dọc
		vs_reg <= HS_POL;
	else if((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_FP - 1))//kết thúc đồng bộ dọc
		vs_reg <= ~vs_reg;  
	else
		vs_reg <= vs_reg;
end
//Hàng hợp lệ
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_active <= 1'd0;
	else if((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))//bắt đầu vùng tích cực dọc
		v_active <= 1'b1;
	else if((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1)) //kết thúc vùng tích cực dọc
		v_active <= 1'b0;   
	else
		v_active <= v_active;
end


endmodule 
