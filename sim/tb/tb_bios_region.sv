`timescale 1ns/1ps
`include "gb3do_pkg.svh"
// Host BIOS loading, automatic PAL detection and 512 KiB ROM address mapping.
// Optional: +bios=<path> +expect_pal=<0|1> runs a real supplied image in both
// host byte orders. Without files, synthetic full-size images exercise all
// four PAL checksums, the NTSC default, reloads and short-ROM handling.
module tb_bios_region;
  import gb3do_pkg::*;
  bit clk=0,clk_mem=0,reset=1;
  always #10 clk=~clk;
  always #5 clk_mem=~clk_mem;
  bit [31:0] mem_address=0,mem_dataWrite=0;
  bit mem_enable=0,mem_write=0,cmd_request=0;
  wire [31:0] mem_dataRead;
  wire mem_done,cmd_busy,cmd_done,cmd_error,core_halt,core_reset_pulse,HOST_LE,bios_loaded,bios_pal,bios_512k;
  wire [1:0] region_sel;
  wire sec_req,sec_we;
  wire [23:0] sec_addr;
  wire [9:0] sec_len;
  wire [15:0] sec_wdata;
  wire [1:0] sec_wbe;
  bit sec_wnext=0,sec_rvalid=0,sec_done=0;
  int state=0,remaining=0;
  gb_host dut(.clk(clk),.reset(reset),.mem_address(mem_address),.mem_enable(mem_enable),.mem_write(mem_write),
    .mem_dataRead(mem_dataRead),.mem_dataWrite(mem_dataWrite),.mem_done(mem_done),
    .cmd_request(cmd_request),.cmd_busy(cmd_busy),.cmd_done(cmd_done),.cmd_error(cmd_error),
    .core_halt(core_halt),.core_reset_pulse(core_reset_pulse),.focus(),.HOST_LE(HOST_LE),
    .disc_present(),.disc_bytes(),.bios_loaded(bios_loaded),.bios_512k(bios_512k),.kanji_loaded(),.cd_speed(),.region_sel(region_sel),
    .button_layout(),.vram_mem(),.bios_pal(bios_pal),.disc_stream(),.disc_change(),.toc_we(),.toc_wa(),.toc_wd(),
    .sb_we(),.sb_wa(),.sb_wd(),.core_cmd_words('{default:'0}),.core_res(),.od_enable(),
    .clk_mem(clk_mem),.rst_mem(reset),.sec_req(sec_req),.sec_we(sec_we),.sec_addr(sec_addr),.sec_len(sec_len),
    .sec_wdata(sec_wdata),.sec_wbe(sec_wbe),.sec_wnext(sec_wnext),.sec_rdata(16'hFFFF),.sec_rvalid(sec_rvalid),.sec_done(sec_done));
  // Complete the public secondary-port transactions. Memory contents are
  // unneeded for the checksum test; data are checksummed on accepted host writes.
  always @(posedge clk_mem) begin
    sec_wnext<=0;sec_rvalid<=0;sec_done<=0;
    if(reset) state<=0;
    else case(state)
      0: if(sec_req) begin remaining<=int'(sec_len);state<=1;end
      1: if(remaining!=0) begin
           if(sec_we) sec_wnext<=1;else sec_rvalid<=1;
           remaining<=remaining-1;
         end else begin sec_done<=1;state<=2;end
      2: if(!sec_req) state<=0;
    endcase
  end

  task automatic access(input bit wr,input bit[31:0] a,d,output bit[31:0] q);
    int to;
    @(negedge clk);mem_address=a;mem_dataWrite=d;mem_write=wr;mem_enable=1;
    @(negedge clk);to=0;
    while(!mem_done) begin @(negedge clk);if(++to>2000)$fatal(1,"Host access timeout");end
    q=mem_dataRead;mem_enable=0;mem_write=0;
    @(negedge clk);
  endtask
  task automatic wr(input bit[31:0] a,d);
    bit [31:0] q;access(1,a,d,q);
  endtask
  task automatic command(input bit[15:0] code,input bit[31:0] arg,size=0);
    int to;
    wr(32'hF0000004,arg);wr(32'hF0000008,size);wr(32'hF0000000,{16'b0,code});
    @(negedge clk);cmd_request=1;to=0;
    do begin @(negedge clk);if(++to>100)$fatal(1,"Command timeout");end while(!cmd_done && !cmd_error);
    if(cmd_error)$fatal(1,"Host command error");
    cmd_request=0;@(negedge clk);@(negedge clk);
  endtask

  byte unsigned bytes[0:1048575];
  int checks=0,failures=0,address_checks=0;
  string image_path="";
  int image_expect_pal=0;

  task automatic check_addresses(input bit short_image);
    for(int kanji=0;kanji<2;kanji++) begin
      for(int i=0;i<4;i++)begin
        bit [19:2] a,expected;
        a=(i==0) ? 18'h00000 : (i==1) ? 18'h1FFFF : (i==2) ? 18'h20000 : 18'h3FFFF;
        expected=(short_image && !kanji) ? 18'(int'(a)%131072) : a;
        address_checks++;
        if(boot_rom_addr(a,bios_512k,kanji[0])!=expected)$fatal(1,"BIOS/Kanji address mapping failed");
      end
    end
  endtask

  task automatic send_image(input int n,input bit expected_pal,input bit big_endian,input bit[31:0] expected_sum);
    bit [31:0] word,selected_sum;
    command(16'h0300,1);
    if(bios_loaded || bios_512k)$fatal(1,"New BIOS load retained previous image state");
    for(int i=0;i<n;i+=4) begin
      word=big_endian ? {bytes[i],bytes[i+1],bytes[i+2],bytes[i+3]} : {bytes[i+3],bytes[i+2],bytes[i+1],bytes[i]};
      wr(32'h20000000+32'(i),word);
    end
    command(16'h0301,1,32'(n));
    repeat(3)@(negedge clk);
    if(!bios_loaded || HOST_LE==big_endian)$fatal(1,"Load/host-byte-order setup failed");
    if(bios_512k!=(n==524288))$fatal(1,"Short BIOS flag incorrect");
    selected_sum=HOST_LE ? dut.bios_sum_le : dut.bios_sum_be;
    checks++;failures+=(bios_pal!=expected_pal);
    $display("BIOS_CASE host_be=%0d expected_pal=%0d detected_pal=%0d checksum=%08x loaded_bytes=%0d short=%0d",big_endian,expected_pal,bios_pal,selected_sum,n,bios_512k);
    if(selected_sum!=expected_sum)$fatal(1,"File checksum was not accumulated correctly");
    check_addresses(n==524288);
    wr(32'h00001008,1);if(region_sel!=1)$fatal(1,"NTSC override failed");
    wr(32'h00001008,2);if(region_sel!=2)$fatal(1,"PAL override failed");
    wr(32'h00001008,0);if(region_sel!=0)$fatal(1,"By BIOS selection failed");
  endtask

  task automatic synthetic_image(input bit[31:0] sum,input int n,input bit expected_pal,input bit be);
    bit[31:0] remaining_sum;
    bit[15:0] value;
    remaining_sum=sum;
    for(int i=0;i<n;i+=2)begin
      value=(remaining_sum>65535) ? 16'hFFFF : 16'(remaining_sum);
      bytes[i]=value[7:0];bytes[i+1]=value[15:8];
      remaining_sum-=32'(value);
    end
    if(remaining_sum!=0)$fatal(1,"Synthetic image too short");
    send_image(n,expected_pal,be,sum);
  endtask

  task automatic load_image(input bit be);
    int fd,n;
    bit[31:0] sum;
    fd=$fopen(image_path,"rb");if(fd==0)$fatal(1,"Cannot open BIOS");
    n=$fread(bytes,fd);$fclose(fd);
    if(n!=1048576 && n!=524288)$fatal(1,"Expected 512 KiB or 1 MiB test image");
    sum=0;
    for(int i=0;i<n;i+=2) sum+=32'({bytes[i+1],bytes[i]});
    send_image(n,image_expect_pal[0],be,sum);
  endtask
  initial begin
    void'($value$plusargs("bios=%s",image_path));
    void'($value$plusargs("expect_pal=%d",image_expect_pal));
    for(int be=0;be<2;be++)begin
      reset=1;repeat(8)@(negedge clk);reset=0;repeat(8)@(negedge clk);
      wr(32'h10000000,be ? 32'h015A5A5A : 32'h5A5A5A01);
      if(image_path!="") load_image(be[0]);
      else begin
        synthetic_image(32'hD63EC5E9,1048576,1,be[0]);
        synthetic_image(32'hD5CFD1C5,1048576,1,be[0]);
        synthetic_image(32'hD439B8FE,1048576,1,be[0]);
        synthetic_image(32'hD439B6FE,1048576,1,be[0]);
        synthetic_image(32'h7733DD21,1048576,0,be[0]);
        synthetic_image(32'h12345678,524288,0,be[0]);
      end
    end
    $display("BIOS_REGION_RESULT full_image_loads=%0d classification_errors=%0d address_checks=%0d",checks,failures,address_checks);
    if(failures)$fatal(1,"BIOS detection failed");
    $finish;
  end
  initial begin #1_000_000_000;$fatal(1,"Simulation deadline");end
endmodule
