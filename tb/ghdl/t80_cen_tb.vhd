-- tb/ghdl/t80_cen_tb.vhd
-- CEN functional test for the T80as Z80 core (clock-rework).
--
-- The rework runs the Z80 on the single 98.304 MHz master clock gated by a
-- clock-enable (cen_cpu, the 4 MHz NCO) instead of a dedicated 4 MHz clock.
-- T80as previously hardwired CEN<='1' internally; it now exposes CEN_i (default
-- '1', so legacy free-running instantiations are unchanged).
--
-- This drives a single core on the master clk gated by a 1-in-4 enable and runs
-- a small program that writes known values to known addresses. If the CPU
-- executes correctly under CEN, the expected writes appear -- proving the
-- exposed CEN port gates the core properly (a clock-enable only inserts idle
-- cycles, it must not change functional behaviour).
--   0000: 3E 5A     LD A,$5A
--   0002: 32 00 40  LD ($4000),A      -> write 4000 = 5A
--   0005: 3C        INC A
--   0006: 32 01 40  LD ($4001),A      -> write 4001 = 5B
--   0009: C3 00 00  JP $0000
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity t80_cen_tb is
end entity;

architecture sim of t80_cen_tb is
  signal clk     : std_logic := '0';
  signal ph      : unsigned(1 downto 0) := "00";
  signal reset_n : std_logic := '0';
  signal cen     : std_logic;
  signal done    : boolean := false;

  signal a    : std_logic_vector(15 downto 0);
  signal di   : std_logic_vector(7 downto 0);
  signal do   : std_logic_vector(7 downto 0);
  signal wr_n, mreq_n, prev_wr : std_logic := '1';

  signal saw_w0, saw_w1 : boolean := false;

  function rom(addr : std_logic_vector(15 downto 0)) return std_logic_vector is
    variable b : std_logic_vector(7 downto 0);
  begin
    case addr is
      when x"0000" => b := x"3E";
      when x"0001" => b := x"5A";
      when x"0002" => b := x"32";
      when x"0003" => b := x"00";
      when x"0004" => b := x"40";
      when x"0005" => b := x"3C";
      when x"0006" => b := x"32";
      when x"0007" => b := x"01";
      when x"0008" => b := x"40";
      when x"0009" => b := x"C3";
      when x"000A" => b := x"00";
      when x"000B" => b := x"00";
      when others  => b := x"00";
    end case;
    return b;
  end function;
begin
  clk <= not clk after 5 ns when not done else '0';
  process(clk) begin if rising_edge(clk) then ph <= ph + 1; end if; end process;
  cen <= '1' when ph = "01" else '0';   -- 4 MHz-style 1-in-4 clock-enable

  di <= rom(a);

  dut : entity work.T80as
    generic map ( Mode => 0 )
    port map (
      RESET_n => reset_n, CLK_n => clk, CEN_i => cen,
      WAIT_n => '1', INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
      M1_n => open, MREQ_n => mreq_n, IORQ_n => open, RD_n => open, WR_n => wr_n,
      RFSH_n => open, HALT_n => open, BUSAK_n => open,
      A => a, DI => di, DO => do, DOE => open
    );

  process
  begin
    reset_n <= '0';
    wait for 80 ns;
    reset_n <= '1';
    wait;
  end process;

  -- capture memory writes (WR_n & MREQ_n asserted) at the enable tick
  process(clk)
  begin
    if rising_edge(clk) then
      if cen = '1' and reset_n = '1' then
        if wr_n = '0' and mreq_n = '0' then
          if a = x"4000" then
            assert do = x"5A" report "FAIL: t80_cen wrote " & to_hstring(do) &
              " to 4000 (expected 5A)" severity failure;
            saw_w0 <= true;
          elsif a = x"4001" then
            assert do = x"5B" report "FAIL: t80_cen wrote " & to_hstring(do) &
              " to 4001 (expected 5B)" severity failure;
            saw_w1 <= true;
          end if;
        end if;
      end if;
    end if;
  end process;

  process
  begin
    wait for 200 us;
    done <= true;
    assert saw_w0 and saw_w1
      report "FAIL: t80_cen (expected writes to 4000/4001 never observed)" severity failure;
    report "PASS: t80_cen" severity note;
    wait;
  end process;
end architecture;
