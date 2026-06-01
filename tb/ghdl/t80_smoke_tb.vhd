-- tb/ghdl/t80_smoke_tb.vhd
-- GHDL smoke test for the T80as (Z80) VHDL core.
--
-- The CPU cores are NOT modified by the clock rework (they are already
-- synchronous posedge-clk + clock-enable designs); only their driving
-- clock/CEN changes at the Verilog wrapper. This test confirms the VHDL flow
-- works and the core is alive: feed it NOPs (DI = 0x00) and verify the address
-- bus advances past 0 after reset (PC increments as NOPs execute). It also
-- doubles as the template for a CEN-driven check: holding CLK_n high and
-- pulsing it only on "enable" cycles is how the wrapper will drive it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity t80_smoke_tb is
end entity;

architecture sim of t80_smoke_tb is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal a       : std_logic_vector(15 downto 0);
  signal di      : std_logic_vector(7 downto 0) := x"00"; -- NOP
  signal m1_n    : std_logic;
  signal saw_nonzero_a : boolean := false;
  signal done    : boolean := false;
begin
  -- ~4 MHz-ish clock (period irrelevant to functional smoke)
  clk <= not clk after 5 ns when not done else '0';

  dut : entity work.T80as
    generic map ( Mode => 0 )
    port map (
      RESET_n => reset_n,
      CLK_n   => clk,
      WAIT_n  => '1',
      INT_n   => '1',
      NMI_n   => '1',
      BUSRQ_n => '1',
      M1_n    => m1_n,
      MREQ_n  => open,
      IORQ_n  => open,
      RD_n    => open,
      WR_n    => open,
      RFSH_n  => open,
      HALT_n  => open,
      BUSAK_n => open,
      A       => a,
      DI      => di,
      DO      => open,
      DOE     => open
    );

  -- reset sequence
  process
  begin
    reset_n <= '0';
    wait for 50 ns;
    reset_n <= '1';
    wait;
  end process;

  -- watch the address bus advance (CPU executing NOPs)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '1' and a /= x"0000" then
        saw_nonzero_a <= true;
      end if;
    end if;
  end process;

  -- verdict at end of run
  process
  begin
    wait for 30 us;
    done <= true;
    assert saw_nonzero_a
      report "FAIL: t80_smoke (address bus never advanced)" severity failure;
    report "PASS: t80_smoke" severity note;
    wait;
  end process;
end architecture;
